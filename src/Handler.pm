=head1 NAME

 Package::SqlAdminTools::PhpMyAdmin::Handler - i-MSCP PhpMyAdmin package handler

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2019 Laurent Declercq <l.declercq@nuxwin.com>
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA

package Package::SqlAdminTools::PhpMyAdmin::Handler;

use strict;
use warnings;
use File::Spec;
use File::Temp;
use iMSCP::Boolean;
use iMSCP::Crypt qw/ decryptRijndaelCBC encryptRijndaelCBC randomStr /;
use iMSCP::Cwd '$CWD';
use iMSCP::Database;
use iMSCP::Debug qw/ debug error /;
use iMSCP::EventManager;
use iMSCP::Execute 'execute';
use iMSCP::File;
use iMSCP::Rights 'setRights';
use iMSCP::TemplateParser qw/ getBloc replaceBloc process /;
use Scalar::Defer 'lazy';
use Servers::sqld;
use parent 'Common::Object';

=head1 DESCRIPTION

 i-MSCP PhpMyAdmin package handler.

=head1 PUBLIC METHODS

=over 4

=item preinstall( )

 Pre-installation tasks

 Return int 0 on success, other on failure

=cut

sub preinstall
{
    my ( $self ) = @_;

    $self->{'events'}->register(
        'afterFrontEndBuildConfFile', \&afterFrontEndBuildConfFile
    );
}

=item install( )

 Installation tasks

 Return int 0 on success, other on failure

=cut

sub install
{
    my ( $self ) = @_;

    local $CWD = $::imscpConfig{'GUI_ROOT_DIR'};

    my $rs ||= $self->_buildConfigFiles();
    $rs ||= $self->_buildHttpdConfigFile();
    $rs ||= $self->_setupDatabase();
    $rs ||= $self->_setupSqlUser();
}

=item postinstall( )

 Post-installation tasks

 Return int 0 on success, other on failure

=cut

sub postinstall
{
    local $CWD = $::imscpConfig{'GUI_ROOT_DIR'};

    if ( -l "$CWD/public/tools/phpmyadmin" ) {
        my $rs = iMSCP::File->new(
            filename => "$CWD/public/tools/phpmyadmin"
        )->delFile();
        return $rs if $rs;
    }

    unless ( symlink( File::Spec->abs2rel(
        "$CWD/vendor/phpmyadmin/phpmyadmin", "$CWD/public/tools"
    ),
        "$CWD/public/tools/phpmyadmin"
    ) ) {
        error( sprintf(
            "Couldn't create symlink for PhpMyAdmin SQL administration tool"
        ));
        return 1;
    }

    0;
}

=item uninstall( )

 Uninstallation tasks

 Return int 0 on success, other on failure

=cut

sub uninstall
{
    my ( $self ) = @_;

    local $CWD = $::imscpConfig{'GUI_ROOT_DIR'};

    if ( -l "$CWD/public/tools/phpmyadmin" ) {
        my $rs = iMSCP::File->new(
            filename => "$CWD/public/tools/phpmyadmin"
        )->delFile();
        return $rs if $rs;
    }

    if ( -f '/etc/nginx/imscp_pma.conf' ) {
        my $rs = iMSCP::File->new(
            filename => '/etc/nginx/imscp_pma.conf'
        )->delFile();
        return $rs if $rs;
    }

    eval {
        local $self->{'dbh'}->{'RaiseError'} = TRUE;

        $self->{'dbh'}->do(
            "DROP DATABASE IF EXISTS @{ [ $self->{'dbh'}->quote_identifier( $::imscpConfig{'DATABASE_NAME'} . '_pma' ) ] }"
        );

        my ( $controlUser ) = @{ $self->{'dbh'}->selectcol_arrayref(
            "SELECT `value` FROM `config` WHERE `name` = 'PMA_CONTROL_USER'"
        ) };

        if ( defined $controlUser ) {
            $controlUser = decryptRijndaelCBC(
                $::imscpDBKey, $::imscpDBiv, $controlUser
            );

            for my $host (
                $::imscpOldConfig{'DATABASE_USER_HOST'},
                $::imscpConfig{'DATABASE_USER_HOST'}
            ) {
                next unless length $host;
                Servers::sqld->factory()->dropUser( $controlUser, $host );
            }
        }

        $self->{'dbh'}->do( "DELETE FROM `config` WHERE `name` LIKE 'PMA_%'" );
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=back

=head1 EVENT LISTENERS

=over 4

=item afterFrontEndBuildConfFile( )

 Event listener that injects Httpd configuration for PhpMyAdmin into the i-MSCP
 control panel Nginx vhost files

 Return int 0 on success, other on failure

=cut

sub afterFrontEndBuildConfFile
{
    my ( $tplContent, $tplName ) = @_;

    return 0 unless grep (
        $_ eq $tplName, '00_master.nginx', '00_master_ssl.nginx'
    );

    ${ $tplContent } = replaceBloc(
        "# SECTION custom BEGIN.\n",
        "# SECTION custom END.\n",
        "    # SECTION custom BEGIN.\n"
            . getBloc(
                "# SECTION custom BEGIN.\n",
                "# SECTION custom END.\n",
                ${ $tplContent }
            )
            . "    include imscp_pma.conf;\n"
            . "    # SECTION custom END.\n",
        ${ $tplContent }
    );

    0;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init( )

 Initialize instance

 Return Package::SqlAdminTools::PhpMyAdmin::Handler

=cut

sub _init
{
    my ( $self ) = @_;

    $self->{'events'} = iMSCP::EventManager->getInstance();
    $self->{'dbh'} = lazy { iMSCP::Database->factory()->getRawDb(); };
    $self;
}

=item _buildConfigFiles( )

 Build PhpMyadminConfiguration files 

 Return int 0 on success, other on failure
  
=cut

sub _buildConfigFiles
{
    my ( $self ) = @_;

    my $rs = eval {
        # Main configuration file
        local $self->{'dbh'}->{'RaiseError'} = TRUE;

        my %config = @{ $self->{'dbh'}->selectcol_arrayref(
            "SELECT `name`, `value` FROM `config` WHERE `name` LIKE 'PMA_%'",
            { Columns => [ 1, 2 ] }
        ) };

        ( $config{'PMA_BLOWFISH_SECRET'} = decryptRijndaelCBC(
            $::imscpDBKey, $::imscpDBiv, $config{'PMA_BLOWFISH_SECRET'} // ''
        ) || randomStr( 32, iMSCP::Crypt::ALPHA64 ) );

        ( $config{'PMA_CONTROL_USER'} = decryptRijndaelCBC(
            $::imscpDBKey, $::imscpDBiv, $config{'PMA_CONTROL_USER'} // ''
        ) || 'pma_' . randomStr( 12, iMSCP::Crypt::ALPHA64 ) );

        ( $config{'PMA_CONTROL_USER_PASSWD'} = decryptRijndaelCBC(
            $::imscpDBKey, $::imscpDBiv, $config{'PMA_CONTROL_USER_PASSWD'} // ''
        ) || randomStr( 16, iMSCP::Crypt::ALPHA64 ) );

        (
            $self->{'_pma_control_user'},
            $self->{'_pma_control_user_passwd'}
        ) = (
            $config{'PMA_CONTROL_USER'}, $config{'PMA_CONTROL_USER_PASSWD'}
        );

        $self->{'dbh'}->do(
            '
                INSERT INTO `config` (`name`,`value`)
                VALUES (?,?),(?,?),(?,?)
                ON DUPLICATE KEY UPDATE `name` = `name`
            ',
            undef,
            'PMA_BLOWFISH_SECRET',
            encryptRijndaelCBC(
                $::imscpDBKey, $::imscpDBiv, $config{'PMA_BLOWFISH_SECRET'}
            ),
            'PMA_CONTROL_USER',
            encryptRijndaelCBC(
                $::imscpDBKey, $::imscpDBiv, $config{'PMA_CONTROL_USER'}
            ),
            'PMA_CONTROL_USER_PASSWD',
            encryptRijndaelCBC(
                $::imscpDBKey, $::imscpDBiv, $config{'PMA_CONTROL_USER_PASSWD'}
            )
        );

        my $data = {
            BLOWFISH_SECRET   => $config{'PMA_BLOWFISH_SECRET'},
            DATABASE_HOSTNAME => ::setupGetQuestion( 'DATABASE_HOST' ),
            DATABASE_PORT     => ::setupGetQuestion( 'DATABASE_PORT' ),
            DATABASE_NAME     => ::setupGetQuestion( 'DATABASE_NAME' ) . '_pma',
            DATABASE_USER     => $config{'PMA_CONTROL_USER'},
            DATABASE_PASSWORD => $config{'PMA_CONTROL_USER_PASSWD'},
            SESSION_SAVE_PATH => "$CWD/data/sessions/",
            TMP_DIR           => "$CWD/data/tmp/"
        };

        my $rs = $self->{'events'}->trigger(
            'onLoadTemplate',
            'phpmyadmin',
            'config.inc.php',
            \my $cfgTpl,
            $data
        );
        return $rs if $rs;

        unless ( defined $cfgTpl ) {
            $cfgTpl = iMSCP::File->new(
                filename => "$CWD/vendor/imscp/phpmyadmin/src/config.inc.php"
            )->get();
            return 1 unless defined $cfgTpl;
        }

        $cfgTpl = process( $data, $cfgTpl );

        my $file = iMSCP::File->new(
            filename => "$CWD/vendor/phpmyadmin/phpmyadmin/config.inc.php"
        );
        $file->set( $cfgTpl );
        $rs = $file->save();
        $rs ||= $file->owner(
            $::imscpConfig{'SYSTEM_USER_PREFIX'} . $::imscpConfig{'SYSTEM_USER_MIN_UID'},
            $::imscpConfig{'SYSTEM_USER_PREFIX'} . $::imscpConfig{'SYSTEM_USER_MIN_UID'}
        );
        return $rs if $rs;

        # Vendor configuration file

        $file = iMSCP::File->new(
            filename => "$CWD/vendor/phpmyadmin/phpmyadmin/libraries/vendor_config.php"
        );
        return 1 unless defined( my $fileC = $file->getAsRef());

        ${ $fileC } =~ s%^define\('AUTOLOAD_FILE',\s+'./vendor/autoload.php'\);
            %define('AUTOLOAD_FILE', '$CWD/vendor/autoload.php');%mx;
        ${ $fileC } =~ s%^define\('TEMP_DIR',\s+'./tmp/'\);
            %define('TEMP_DIR', '$CWD/data/tmp/');%mx;
        ${ $fileC } =~ s%^define\('VERSION_CHECK_DEFAULT',\s+true\);
            %define\('VERSION_CHECK_DEFAULT', false);%mx;

        $file->save();
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    $rs;
}

=item _buildHttpdConfigFile( )

 Build httpd configuration file for PhpMyAdmin 

 Return int 0 on success, other on failure

=cut

sub _buildHttpdConfigFile
{
    my $rs = iMSCP::File->new(
        filename => "$CWD/vendor/imscp/phpmyadmin/src/nginx.conf"
    )->copyFile( '/etc/nginx/imscp_pma.conf' );
    return $rs if $rs;

    my $file = iMSCP::File->new( filename => '/etc/nginx/imscp_pma.conf' );
    return 1 unless defined( my $fileC = $file->getAsRef());

    ${ $fileC } = process( { GUI_ROOT_DIR => $CWD }, ${ $fileC } );

    $file->save();
}

=item _setupDatabase( )

 Setup datbase for PhpMyAdmin

 Return int 0 on success, other on failure

=cut

sub _setupDatabase
{
    my ( $self ) = @_;

    my $database = ::setupGetQuestion( 'DATABASE_NAME' ) . '_pma';

    eval {
        local $self->{'dbh'}->{'RaiseError'} = TRUE;
        $self->{'dbh'}->do( sprintf(
            'DROP DATABASE IF EXISTS %s',
            $self->{'dbh'}->quote_identifier( $database )
        ));
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    my $schemaFile = File::Temp->new();

    my $file = iMSCP::File->new(
        filename => "$CWD/vendor/phpmyadmin/phpmyadmin/sql/create_tables.sql"
    );
    return 1 unless defined( my $fileC = $file->getAsRef());

    ${ $fileC } =~ s/\bphpmyadmin\b/$database/gm;

    print $schemaFile ${ $fileC };
    $schemaFile->close();

    my $rs = execute(
        "/usr/bin/mysql < $schemaFile",
        \my $stdout,
        \my $stderr
    );
    debug( $stdout ) if $stdout;
    error( $stderr || 'Unknown error' ) if $rs;
    $rs;
}

=item _setupSqlUser( )

 Setup SQL user for PhpMyAdmin 

 Return int 0 on success, other on failure

=cut

sub _setupSqlUser
{
    my ( $self ) = @_;

    eval {
        my $database = ::setupGetQuestion( 'DATABASE_NAME' ) . '_pma';
        my $dbUserHost = ::setupGetQuestion( 'DATABASE_USER_HOST' );
        my $sqlServer = Servers::sqld->factory();

        for my $host (
            $::imscpOldConfig{'DATABASE_USER_HOST'},
            $dbUserHost
        ) {
            next unless length $host;
            $sqlServer->dropUser( $self->{'_pma_control_user'}, $host );
        }

        $sqlServer->createUser(
            $self->{'_pma_control_user'},
            $dbUserHost,
            $self->{'_pma_control_user_passwd'}
        );

        local $self->{'dbh'}->{'RaiseError'} = TRUE;

        $self->{'dbh'}->do(
            'GRANT USAGE ON mysql.* TO ?@?',
            undef,
            $self->{'_pma_control_user'},
            $dbUserHost
        );
        $self->{'dbh'}->do(
            '
                GRANT SELECT (
                    Host, User, Select_priv, Insert_priv, Update_priv,
                    Delete_priv, Create_priv, Drop_priv, Reload_priv,
                    Shutdown_priv, Process_priv, File_priv, Grant_priv,
                    References_priv, Index_priv, Alter_priv, Show_db_priv,
                    Super_priv, Create_tmp_table_priv, Lock_tables_priv,
                    Execute_priv, Repl_slave_priv, Repl_client_priv
                ) ON mysql.user TO ?@?
            ',
            undef, $self->{'_pma_control_user'}, $dbUserHost
        );

        $self->{'dbh'}->do(
            'GRANT SELECT ON mysql.db TO ?@?',
            undef,
            $self->{'_pma_control_user'},
            $dbUserHost
        );

        # Check for mysql.host table existence (as for MySQL >= 5.6.7, the
        # mysql.host table is no longer provided)
        if ( $self->{'dbh'}->selectrow_hashref(
            "SHOW tables FROM mysql LIKE 'host'"
        ) ) {
            $self->{'dbh'}->do(
                'GRANT SELECT ON mysql.host TO ?@?',
                undef,
                $self->{'_pma_control_user'},
                $dbUserHost
            );
        }

        $self->{'dbh'}->do(
            'GRANT SELECT ON mysql.user TO ?@?',
            undef,
            $self->{'_pma_control_user'},
            $dbUserHost
        );
        $self->{'dbh'}->do(
            '
                GRANT SELECT (
                    Host, Db, User, Table_name, Table_priv, Column_priv
                ) ON mysql.tables_priv
                TO?@?
            ',
            undef,
            $self->{'_pma_control_user'},
            $dbUserHost
        );

        $self->{'dbh'}->do(
            "
                GRANT SELECT, INSERT, UPDATE, DELETE
                ON @{ [
                $self->{'dbh'}->quote_identifier(
                    $database
                ) =~ s/([%_])/\\$1/gr
            ] }.*
                TO ?\@?
            ",
            undef,
            $self->{'_pma_control_user'},
            $dbUserHost
        );
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
