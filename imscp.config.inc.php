<?php
/* vim: set expandtab sw=4 ts=4 sts=4: */
/**
 * phpMyAdmin sample configuration, you can use it as base for
 * manual configuration. For easier setup you can use setup/
 *
 * All directives are explained in documentation in the doc/ folder
 * or at <http://docs.phpmyadmin.net/>.
 *
 * @package PhpMyAdmin
 */

/**
 * This is needed for cookie based authentication to encrypt password in
 * cookie
 */
$cfg['blowfish_secret'] = '{BLOWFISH}'; /* YOU MUST FILL IN THIS FOR COOKIE AUTH! */

/**
 * Servers configuration
 */
$i = 0;

/**
 * First server
 */
$i++;
/* Authentication type */
$cfg['Servers'][$i]['auth_type'] = 'cookie';
/* Server parameters */
$cfg['Servers'][$i]['host'] = '{HOSTNAME}';
$cfg['Servers'][$i]['port'] = '{PORT}';
//$cfg['Servers'][$i]['connect_type'] = 'tcp';
$cfg['Servers'][$i]['compress'] = true;
$cfg['Servers'][$i]['AllowNoPassword'] = false;

/**
 * phpMyAdmin configuration storage settings.
 */

/* User used to manipulate with storage */
$cfg['Servers'][$i]['controlhost'] = '{HOSTNAME}';
$cfg['Servers'][$i]['controlport'] = '{PORT}';
$cfg['Servers'][$i]['controluser'] = '{PMA_USER}';
$cfg['Servers'][$i]['controlpass'] = '{PMA_PASS}';

/* Storage database and tables */
$cfg['Servers'][$i]['pmadb'] = '{PMA_DATABASE}';
$cfg['Servers'][$i]['bookmarktable'] = 'pma__bookmark';
$cfg['Servers'][$i]['relation'] = 'pma__relation';
$cfg['Servers'][$i]['table_info'] = 'pma__table_info';
$cfg['Servers'][$i]['table_coords'] = 'pma__table_coords';
$cfg['Servers'][$i]['pdf_pages'] = 'pma__pdf_pages';
$cfg['Servers'][$i]['column_info'] = 'pma__column_info';
$cfg['Servers'][$i]['history'] = 'pma__history';
$cfg['Servers'][$i]['table_uiprefs'] = 'pma__table_uiprefs';
$cfg['Servers'][$i]['tracking'] = 'pma__tracking';
$cfg['Servers'][$i]['userconfig'] = 'pma__userconfig';
$cfg['Servers'][$i]['recent'] = 'pma__recent';
$cfg['Servers'][$i]['favorite'] = 'pma__favorite';
$cfg['Servers'][$i]['users'] = 'pma__users';
$cfg['Servers'][$i]['usergroups'] = 'pma__usergroups';
$cfg['Servers'][$i]['navigationhiding'] = 'pma__navigationhiding';
$cfg['Servers'][$i]['savedsearches'] = 'pma__savedsearches';
$cfg['Servers'][$i]['central_columns'] = 'pma__central_columns';
$cfg['Servers'][$i]['designer_settings'] = 'pma__designer_settings';
$cfg['Servers'][$i]['export_templates'] = 'pma__export_templates';

/**
 * Hidden databases
 */
$cfg['Servers'][$i]['hide_db'] = '(information_schema|performance_schema|mysql|sys)';

/**
 * End of servers configuration
 */

/**
 * Warnings configuration
 */
$cfg['PmaNoRelation_DisableWarning'] = true;
$cfg['SuhosinDisableWarning'] = true;
$cfg['ServerLibraryDifference_DisableWarning'] = true;

/**
 * Disable new version check
 */
$cfg['VersionCheck'] = false;

/**
 * Directories for saving/loading files from server
 */
$cfg['UploadDir'] = '{UPLOADS_DIR}';
//$cfg['SaveDir'] = '';

/**
 * Whether or not to query the user before sending the error report to
 * the phpMyAdmin team when a JavaScript error occurs
 *
 * Available options
 * ('ask' | 'always' | 'never')
 * default = 'ask'
 */
$cfg['SendErrorReports'] = 'never';

/**
 * Extra parameters
 */

$cfg['ShowPhpInfo'] = false;
$cfg['ShowChgPassword'] = false;
$cfg['AllowArbitraryServer'] = false;
$cfg['LoginCookieValidity'] = 1440;
$cfg['BrowseMIME'] = true;
$cfg['PDFDefaultPageSize'] = 'A4';
$cfg['DefaultCharset'] = 'utf-8';
$cfg['RecodingEngine'] = 'iconv';
$cfg['AllowAnywhereRecoding'] = true;
$cfg['IconvExtraParams'] = '//TRANSLIT';
$cfg['GD2Available'] = 'yes';

/**
 * You can find more configuration options in the documentation
 * in the doc/ folder or at <http://docs.phpmyadmin.net/>.
 */
