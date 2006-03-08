use strict;
use warnings FATAL => 'all';

use Test::More;
use Apache::Test qw{:withtestmore};
use Apache::TestUtil;
use Apache::TestUtil qw/t_write_shell_script t_write_perl_script/;
use Apache::TestRequest qw{GET_BODY GET};
use DBI;
use DBD::SQLite;
use File::Basename 'dirname';

plan tests=>12;
#plan 'no_plan';

my $serverroot=Apache::Test::vars->{serverroot};
my $documentroot=Apache::Test::vars->{documentroot};
my ($db,$user,$pw)=@ENV{qw/DB USER PW/};
unless( defined $db and length $db ) {
  ($db,$user,$pw)=("dbi:SQLite:dbname=$serverroot/test.sqlite", '', '');
}
t_debug "Using DB=$db USER=$user";
my $dbh;

my $data;

sub update_db {
  $dbh->do('DELETE FROM trans');

  my $stmt=$dbh->prepare( <<'SQL' );
INSERT INTO trans (id, xkey, xuri, xblock, xorder, xaction) VALUES (?,?,?,?,?,?)
SQL

  my $header=<<'EOD';
#id	xkey	xuri	xblock	xorder	xaction
0	default	:PRE:	0	0	Do: $DEBUG=0
1	default	:PRE:	0	1	Key: 'k'
EOD

  foreach my $l (grep !/^\s*#/, split /\n/, $header) {
    $stmt->execute(split /\t+/, $l);
  }

  if( defined $data and length $data ) {
    foreach my $l (grep !/^\s*#/, split /\n/, $data) {
      $stmt->execute(split /\t+/, $l);
    }
  }

  $dbh->do('UPDATE cache SET v=v+1');
}

sub prepare_db {
  $dbh=DBI->connect( $db, $user, $pw,
		     {AutoCommit=>1, PrintError=>0, RaiseError=>1} )
    or die "ERROR: Cannot connect to $db: $DBI::errstr\n";

  eval {
    $dbh->do( <<'SQL' );
CREATE TABLE cache ( v int )
SQL
    $dbh->do( <<'SQL' );
INSERT INTO cache( v ) VALUES( 0 )
SQL
  } or $dbh->do( <<'SQL' );
UPDATE cache SET v=v+1
SQL

  eval {
    $dbh->do( <<'SQL' );
CREATE TABLE trans ( id int, xkey text, xuri text, xblock int, xorder int, xaction text )
SQL
  } or $dbh->do( <<'SQL' );
DELETE FROM trans
SQL

  update_db
}

prepare_db;
sub n {my @c=caller; $c[1].'('.$c[2].'): '.$_[0];}

Apache::TestRequest::user_agent(reset => 1, requests_redirectable => 0);

######################################################################
## the real tests begin here                                        ##
######################################################################

$data=<<'EOD';
#id	xkey	xuri	xblock	xorder	xaction
#                                       a subsequent mod_alias handler maps /ALIAS do DOC_ROOT/alias
10	k	/alias	0	0	Uri: '/ALIAS'.$MATCHED_PATH_INFO
11	k	/file	0	0	File: $r->document_root.$MATCHED_PATH_INFO
12	k	/cgi	0	0	Cgiscript
13	k	/cgi	0	1	File: $r->document_root.$MATCHED_PATH_INFO
14	k	/perl	0	0	Perlscript
15	k	/perl	0	1	File: $r->document_root.$MATCHED_PATH_INFO
16	k	/tsthnd	0	0	Perlhandler: 'TestHandler'
17	k	/tstp	0	0	Perlhandler: 'TestHandler::pathinfo'
18	k	/conf	0	0	Perlhandler: 'TestConfig'
19	k	/conf/1	0	0	Config: 'TestHandlerConfig 1'
20	k	/conf/2	0	0	Config: ['TestHandlerConfig 1']
21	k	/conf/3	0	0	Config: ['TestHandlerConfig 1', '/path']
22	k	/conf/4	0	0	Config: ['TestHandlerConfig 1', '']
23	k	/proxy	0	0	Proxy: 'http://'.join(':', $r->get_server_name, $r->get_server_port).'/tstp'.$MATCHED_PATH_INFO
24	k	/proxy	0	1	Config: ['LogLevel warn', '']
EOD
update_db;

t_write_file( $documentroot.'/ok.html', 'OK' );
t_write_perl_script( $documentroot.'/script.pl', 'print "Content-Type: text/plain\n\n".($ENV{MOD_PERL}||$ENV{GATEWAY_INTERFACE});' );

ok t_cmp GET_BODY( '/ok.html' ), 'OK', n '/ok.html';

SKIP: {
  skip "Need alias module", 1 unless( need_module( 'alias' ) );
  ok t_cmp GET_BODY( '/alias/ok.html' ), 'OK', n '/alias/ok.html';
}

ok t_cmp GET_BODY( '/file/ok.html' ), 'OK', n '/file/ok.html';

SKIP: {
  skip "Need cgi module", 1 unless( need_module( 'cgi' ) );
  ok t_cmp GET_BODY( '/cgi/script.pl' ), qr!^CGI/!, n '/cgi/script.pl';
}

ok t_cmp GET_BODY( '/perl/script.pl' ), qr!^mod_perl/!, n '/perl/script.pl';

t_client_log_warn_is_expected();
ok t_cmp GET_BODY( '/tsthnd' ), $serverroot.'/pm/TestHandler.pm', n '/tsthnd';

ok t_cmp GET_BODY( '/tstp/path/info' ), '/path/info', n '/tstp/path/info';

ok t_cmp GET_BODY( '/conf/1' ), '/conf/1', n '/conf/1';
ok t_cmp GET_BODY( '/conf/2' ), '/', n '/conf/2';
ok t_cmp GET_BODY( '/conf/3' ), '/path', n '/conf/3';
ok t_cmp GET_BODY( '/conf/4' ), 'UNDEF', n '/conf/4';

SKIP: {
  skip "Need proxy and proxy_http modules", 1 unless( need_module( ['proxy','proxy_http'] ) );
  t_client_log_warn_is_expected();
  ok t_cmp GET_BODY( '/proxy/path/info' ), '/path/info', n '/proxy/path/info';
}

$dbh->do('DELETE FROM trans');
$dbh->disconnect;

__END__
# Local Variables: #
# mode: cperl #
# End: #
