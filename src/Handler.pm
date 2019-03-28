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
use Servers::sqld;
use parent 'Common::Object';

=head1 DESCRIPTION

 i-MSCP PhpMyAdmin package handler.

=head1 PUBLIC METHODS

=over 4

=item preinstall( )

 Process pre-installation tasks

 Return int 0 on success, other on failure

=cut

sub preinstall
{
    my ( $self ) = @_;

    $self->{'eventManager'}->register( 'afterFrontEndBuildConfFile', \&afterFrontEndBuildConfFile );
}

=item install( )

 Process installation tasks

 Return int 0 on success, other on failure

=cut

sub install
{
    my ( $self ) = @_;

    my $rs ||= $self->_buildConfigFiles();
    $rs ||= $self->_buildHttpdConfigFile();
    $rs ||= $self->_setupDatabase();
    $rs ||= $self->_setupSqlUser();
}

=item postinstall( )

 Process post-installation tasks

 Return int 0 on success, other on failure

=cut

sub postinstall
{
    local $CWD = $::imscpConfig{'GUI_ROOT_DIR'};

    if ( -l "./public/tools/phpmyadmin" ) {
        my $rs = iMSCP::File->new( filename => './public/tools/phpmyadmin' )->delFile();
        return $rs if $rs;
    }

    unless ( symlink( File::Spec->abs2rel( "$CWD/vendor/phpmyadmin/phpmyadmin", "$CWD/public/tools" ), "$CWD/public/tools/phpmyadmin" ) ) {
        error( sprintf( "Couldn't create symlink for PhpMyAdmin SQL administration tool" ));
        return 1;
    }

    0;
}

=item uninstall( )

 Process uninstallation tasks

 Return int 0 on success, other on failure

=cut

sub uninstall
{
    local $CWD = $::imscpConfig{'GUI_ROOT_DIR'};

    if ( -l './public/tools/phpmyadmin' ) {
        my $rs = iMSCP::File->new( filename => './public/tools/phpmyadmin' )->delFile();
        return $rs if $rs;
    }

    eval {
        my $db = iMSCP::Database->factory();
        my $dbh = $db->getRawDb();

        local $dbh->{'RaiseError'} = TRUE;

        $dbh->do( sprintf( 'DROP DATABASE IF EXISTS %s', $dbh->quote_identifier( $::imscpConfig{'DATABASE_NAME'} . '_pma' )));

        if ( defined( my $controlUser = @{ $dbh->selectcol_arrayref( "SELECT `value` FROM `config` WHERE `name` = 'PMA_CONTROL_USER'" ) } ) ) {
            Servers::sqld->factory()->dropUser( decryptRijndaelCBC(
                $::imscpDBKey, $::imscpDBiv, $controlUser ),
                $::imscpConfig{'DATABASE_USER_HOST'}
            );
        }

        $dbh->do( "DELETE FROM `config` WHERE `name` LIKE 'PMA_%'" );
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

 Event listener that inject Httpd configuration for PhpMyAdmin into the i-MSCP Nginx vhost files

 Return int 0 on success, other on failure

=cut

sub afterFrontEndBuildConfFile
{
    my ( $tplContent, $tplName ) = @_;

    return 0 unless grep ($_ eq $tplName, '00_master.nginx', '00_master_ssl.nginx');

    ${ $tplContent } = replaceBloc(
        "# SECTION custom BEGIN.\n",
        "# SECTION custom END.\n",
        "    # SECTION custom BEGIN.\n"
            . getBloc( "# SECTION custom BEGIN.\n", "# SECTION custom END.\n", ${ $tplContent } )
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

    $self->{'eventManager'} = iMSCP::EventManager->getInstance();
    $self;
}

=item _buildConfigFiles( )

 Build PhpMyadminConfiguration files 

 Return int 0 on success, other on failure
  
=cut

sub _buildConfigFiles
{
    my ( $self ) = @_;

    # Main configuration file

    my $db = iMSCP::Database->factory();
    my $dbh = $db->getRawDb();

    my %config = eval {
        local $dbh->{'RaiseError'} = TRUE;
        @{ $dbh->selectcol_arrayref( "SELECT `name`, `value` FROM `config` WHERE `name` LIKE 'PMA_%'", { Columns => [ 1, 2 ] } ) };
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    ( $config{'PMA_BLOWFISH_SECRET'} = decryptRijndaelCBC(
        $::imscpDBKey, $::imscpDBiv, $config{'PMA_BLOWFISH_SECRET'} // ''
    ) || randomStr( 32, iMSCP::Crypt::ALPHA64 ) );

    ( $config{'PMA_CONTROL_USER'} = decryptRijndaelCBC(
        $::imscpDBKey, $::imscpDBiv, $config{'PMA_CONTROL_USER'} // ''
    ) || 'pma_' . randomStr( 12, iMSCP::Crypt::ALPHA64 ) );

    ( $config{'PMA_CONTROL_USER_PASSWD'} = decryptRijndaelCBC(
        $::imscpDBKey, $::imscpDBiv, $config{'PMA_CONTROL_USER_PASSWD'} // ''
    ) || randomStr( 16, iMSCP::Crypt::ALPHA64 ) );

    ( $self->{'_pma_control_user'}, $self->{'_pma_control_user_passwd'} ) = (
        $config{'PMA_CONTROL_USER'}, $config{'PMA_CONTROL_USER_PASSWD'}
    );

    eval {
        local $dbh->{'RaiseError'} = TRUE;
        $dbh->do(
            'INSERT INTO `config` (`name`,`value`) VALUES(?,?),(?,?),(?,?) ON DUPLICATE KEY UPDATE `name` = `name`',
            undef,
            'PMA_BLOWFISH_SECRET', encryptRijndaelCBC( $::imscpDBKey, $::imscpDBiv, $config{'PMA_BLOWFISH_SECRET'} ),
            'PMA_CONTROL_USER', encryptRijndaelCBC( $::imscpDBKey, $::imscpDBiv, $config{'PMA_CONTROL_USER'} ),
            'PMA_CONTROL_USER_PASSWD', encryptRijndaelCBC( $::imscpDBKey, $::imscpDBiv, $config{'PMA_CONTROL_USER_PASSWD'} )
        );
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    local $CWD = $::imscpConfig{'GUI_ROOT_DIR'};

    my $data = {
        PMA_BLOWFISH_SECRET          => $config{'PMA_BLOWFISH_SECRET'},
        PMA_DATABASE_SERVER_HOSTNAME => ::setupGetQuestion( 'DATABASE_HOST' ),
        PMA_DATABASE_SERVER_PORT     => ::setupGetQuestion( 'DATABASE_PORT' ),
        PMA_CONTROL_USER             => $config{'PMA_CONTROL_USER'},
        PMA_CONTROL_USER_PASSWD      => $config{'PMA_CONTROL_USER_PASSWD'},
        PMA_DATABASE                 => ::setupGetQuestion( 'DATABASE_NAME' ) . '_pma',
        PMA_SESSION_SAVE_PATH        => $CWD . '/data/sessions/',
        PMA_TMP_DIR                  => $CWD . '/data/tmp/'
    };

    my $rs = $self->{'eventManager'}->trigger( 'onLoadTemplate', 'phpmyadmin', 'config.inc.php', \my $cfgTpl, $data );
    return $rs if $rs;

    unless ( defined $cfgTpl ) {
        $cfgTpl = iMSCP::File->new( filename => './vendor/imscp/phpmyadmin/src/config.inc.php' )->get();
        return 1 unless defined $cfgTpl;
    }

    $cfgTpl = process( $data, $cfgTpl );

    my $ug = $::imscpConfig{'SYSTEM_USER_PREFIX'} . $::imscpConfig{'SYSTEM_USER_MIN_UID'};
    my $file = iMSCP::File->new( filename => './vendor/phpmyadmin/phpmyadmin/config.inc.php' );
    $file->set( $cfgTpl );
    $rs = $file->save();
    $rs ||= $file->owner( $ug, $ug );
    return $rs if $rs;

    # Vendor configuration file

    $file = iMSCP::File->new( filename => './vendor/phpmyadmin/phpmyadmin/libraries/vendor_config.php' );
    return 1 unless defined( my $fileContent = $file->getAsRef());

    ${ $fileContent } =~ s%^define\('AUTOLOAD_FILE',\s+'./vendor/autoload.php'\);%define('AUTOLOAD_FILE', '$CWD/vendor/autoload.php');%m;
    ${ $fileContent } =~ s%^define\('TEMP_DIR',\s+'./tmp/'\);%define('TEMP_DIR', '$CWD/data/tmp/');%m;
    ${ $fileContent } =~ s%^define\('VERSION_CHECK_DEFAULT',\s+true\);%define\('VERSION_CHECK_DEFAULT', false);%m;

    $file->save();
}

=item _buildHttpdConfigFile( )

 Build httpd configuration file for PhpMyAdmin 

 Return int 0 on success, other on failure

=cut

sub _buildHttpdConfigFile
{
    my $rs = iMSCP::File->new( filename => "$::imscpConfig{'GUI_ROOT_DIR'}/vendor/imscp/phpmyadmin/src/nginx.conf" )->copyFile(
        '/etc/nginx/imscp_pma.conf'
    );
    return $rs if $rs;

    my $file = iMSCP::File->new( filename => '/etc/nginx/imscp_pma.conf' );
    return 1 unless defined( my $fileContent = $file->getAsRef());

    ${ $fileContent } = process( { GUI_ROOT_DIR => $::imscpConfig{'GUI_ROOT_DIR'} }, ${ $fileContent } );

    $file->save();
}

=item _setupDatabase( )

 Setup datbase for PhpMyAdmin

 Return int 0 on success, other on failure

=cut

sub _setupDatabase
{
    local $CWD = $::imscpConfig{'GUI_ROOT_DIR'};

    my $database = ::setupGetQuestion( 'DATABASE_NAME' ) . '_pma';
    my $db = iMSCP::Database->factory();
    my $dbh = $db->getRawDb();

    eval {
        local $dbh->{'RaiseError'} = TRUE;
        $dbh->do( sprintf( "DROP DATABASE IF EXISTS %s", $dbh->quote_identifier( $database )));
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    my $schemaFile = File::Temp->new();

    my $file = iMSCP::File->new( filename => './vendor/phpmyadmin/phpmyadmin/sql/create_tables.sql' );
    return 1 unless defined( my $fileContent = $file->getAsRef());

    ${ $fileContent } =~ s/\bphpmyadmin\b/$database/gm;

    print $schemaFile ${ $fileContent };
    $schemaFile->close();

    my $rs = execute( "/usr/bin/mysql < $schemaFile", \my $stdout, \my $stderr );
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

    my $database = ::setupGetQuestion( 'DATABASE_NAME' ) . '_pma';
    my $dbUserHost = ::setupGetQuestion( 'DATABASE_USER_HOST' );
    my $sqlServer = Servers::sqld->factory();

    $sqlServer->dropUser( $self->{'_pma_control_user'}, $dbUserHost );
    $sqlServer->createUser( $self->{'_pma_control_user'}, $dbUserHost, $self->{'_pma_control_user_passwd'} );

    eval {
        my $db = iMSCP::Database->factory();
        my $dbh = $db->getRawDb();

        local $dbh->{'RaiseError'} = TRUE;

        $dbh->do( 'GRANT USAGE ON mysql.* TO ?@?', undef, $self->{'_pma_control_user'}, $dbUserHost );
        $dbh->do( 'GRANT SELECT ON mysql.db TO ?@?', undef, $self->{'_pma_control_user'}, $dbUserHost );
        $dbh->do(
            '
                GRANT SELECT (
                    Host, User, Select_priv, Insert_priv, Update_priv, Delete_priv, Create_priv, Drop_priv, Reload_priv, Shutdown_priv, Process_priv,
                    File_priv, Grant_priv, References_priv, Index_priv, Alter_priv, Show_db_priv, Super_priv, Create_tmp_table_priv, Lock_tables_priv,
                    Execute_priv, Repl_slave_priv, Repl_client_priv
                ) ON mysql.user TO ?@?
            ',
            undef, $self->{'_pma_control_user'}, $dbUserHost
        );

        # Check for mysql.host table existence (as for MySQL >= 5.6.7, the
        # mysql.host table is no longer provided)
        if ( $dbh->selectrow_hashref( "SHOW tables FROM mysql LIKE 'host'" ) ) {
            $dbh->do( 'GRANT SELECT ON mysql.user TO ?@?', undef, $self->{'_pma_control_user'}, $dbUserHost );
        }

        $dbh->do(
            'GRANT SELECT (Host, Db, User, Table_name, Table_priv, Column_priv) ON mysql.tables_priv TO?@?',
            undef, $self->{'_pma_control_user'}, $dbUserHost
        );

        ( my $quotedDbName = $dbh->quote_identifier( $database ) ) =~ s/([%_])/\\$1/g;
        $dbh->do( "GRANT SELECT, INSERT, UPDATE, DELETE ON $quotedDbName.* TO ?\@?", undef, $self->{'_pma_control_user'}, $dbUserHost );
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
