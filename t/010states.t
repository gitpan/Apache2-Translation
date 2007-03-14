use strict;
use warnings FATAL => 'all';

use Apache::Test qw{:withtestmore};
use Test::More;
use Apache::TestUtil;
use Apache::TestRequest qw{GET_BODY GET};
use DBI;
use DBD::SQLite;
use File::Basename 'dirname';

plan tests=>23;
#plan 'no_plan';

my $serverroot=Apache::Test::vars->{serverroot};
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
1	default	:PRE:	0	1	Do: $r->notes->{t}=$r->notes->{t}." init";
2	default	:PRE:	0	2	PerlHandler: 'My::Handler'
3	default	:PRE:	0	3	Key: 'k'
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
}

prepare_db;
sub n {my @c=caller; $c[1].'('.$c[2].'): '.$_[0];}

Apache::TestRequest::user_agent(reset => 1, requests_redirectable => 0);

######################################################################
## the real tests begin here                                        ##
######################################################################

# test key change during :PRE:
$data=<<'EOD';
#id	xkey	xuri	xblock	xorder	xaction
10	k	:PRE:	0	0	Do: $r->notes->{t}=$r->notes->{t}." pre"
EOD
update_db;

ok t_cmp GET_BODY( '/' ), 'init pre', n 'init';

# test normal processing
$data=<<'EOD';
#id	xkey	xuri	xblock	xorder	xaction
10	k	/	0	0	Do: $r->notes->{t}=$r->notes->{t}." /"
11	k	/uri	0	0	Do: $r->notes->{t}=$r->notes->{t}." /uri"
EOD
update_db;

ok t_cmp GET_BODY( '/' ), 'init /', n '/';
ok t_cmp GET_BODY( '/uri' ), 'init /uri /', n '/uri';
ok t_cmp GET_BODY( '/uri/klaus' ), 'init /uri /', n '/uri/klaus';
ok t_cmp GET_BODY( '/klaus' ), 'init /', n '/klaus';

# conditional processing
$data=<<'EOD';
#id	xkey	xuri	xblock	xorder	xaction
10	k	:PRE:	0	0	Do: $r->notes->{t}=$r->notes->{t}." 0_0"
11	k	:PRE:	0	1	Cond: 0
12	k	:PRE:	0	2	Do: $r->notes->{t}=$r->notes->{t}." 0_2"
13	k	:PRE:	1	0	Do: $r->notes->{t}=$r->notes->{t}." 1_0"
EOD
update_db;

ok t_cmp GET_BODY( '/' ), 'init 0_0 1_0', n 'Cond';

# loop back to :PRE: from PROC with a changed key
$data=<<'EOD';
#id	xkey	xuri	xblock	xorder	xaction
10	k	:PRE:	0	0	Do: $r->notes->{t}=$r->notes->{t}." prek"
11	k	/	0	0	Do: $r->notes->{t}=$r->notes->{t}." urik"
12	k	/	0	1	Key: 'k2'
13	k	/	0	2	State: 'PREPROC'
14	k2	:PRE:	0	0	Do: $r->notes->{t}=$r->notes->{t}." prek2"
15	k2	/	0	0	Do: $r->notes->{t}=$r->notes->{t}." urik2"
EOD
update_db;

ok t_cmp GET_BODY( '/' ), 'init prek urik prek2 urik2', n 'Key State';

# 'Done' finishes current state
$data=<<'EOD';
#id	xkey	xuri	xblock	xorder	xaction
10	k	:PRE:	0	0	Do: $r->notes->{t}=$r->notes->{t}." pre0"
11	k	:PRE:	0	1	Done
12	k	:PRE:	1	0	Do: $r->notes->{t}=$r->notes->{t}." pre1"
13	k	/	0	0	Do: $r->notes->{t}=$r->notes->{t}." uri"
EOD
update_db;

ok t_cmp GET_BODY( '/' ), 'init pre0 uri', n 'Done';

# skip PROC state by jumping from PREPROC to DONE
$data=<<'EOD';
#id	xkey	xuri	xblock	xorder	xaction
10	k	:PRE:	0	0	Do: $r->notes->{t}=$r->notes->{t}." pre0"
11	k	:PRE:	0	1	State: 'DONE'
12	k	:PRE:	0	2	Last
13	k	:PRE:	1	0	Do: $r->notes->{t}=$r->notes->{t}." pre1"
14	k	/	0	0	Do: $r->notes->{t}=$r->notes->{t}." uri"
15	k	/uri	0	0	Do: $r->notes->{t}=$r->notes->{t}." uri2"
EOD
update_db;

ok t_cmp GET_BODY( '/' ), 'init pre0', n 'State Last';
ok t_cmp GET_BODY( '/uri' ), 'init pre0', n 'State Last 2';

# skip PROC state by jumping from PREPROC to DONE but complete PREPROC first
$data=<<'EOD';
#id	xkey	xuri	xblock	xorder	xaction
10	k	:PRE:	0	0	Do: $r->notes->{t}=$r->notes->{t}." pre0"
11	k	:PRE:	0	1	State: 'DONE'
12	k	:PRE:	1	0	Do: $r->notes->{t}=$r->notes->{t}." pre1"
13	k	/	0	0	Do: $r->notes->{t}=$r->notes->{t}." uri"
14	k	/uri	0	0	Do: $r->notes->{t}=$r->notes->{t}." uri2"
EOD
update_db;

ok t_cmp GET_BODY( '/' ), 'init pre0 pre1', n 'Last alone';
ok t_cmp GET_BODY( '/uri' ), 'init pre0 pre1', n 'Last alone 2';

# using 'Done' to prematurely finish PROC state
$data=<<'EOD';
#id	xkey	xuri	xblock	xorder	xaction
10	k	/	0	0	Do: $r->notes->{t}=$r->notes->{t}." /"
11	k	/uri	0	0	Do: $r->notes->{t}=$r->notes->{t}." /uri"
12	k	/uri	0	1	Done
EOD
update_db;

ok t_cmp GET_BODY( '/uri' ), 'init /uri', n 'Done';

# CALL
$data=<<'EOD';
#id	xkey	xuri	xblock	xorder	xaction
10	k	/	0	0	Do: $r->notes->{t}=$r->notes->{t}." /:before"
11	k	/	0	1	Call: ':CALL:'
12	k	/	0	2	Do: $r->notes->{t}=$r->notes->{t}." /:after"
13	k	/uri	0	0	Do: $r->notes->{t}=$r->notes->{t}." /uri:before"
14	k	/uri	0	1	Call: ':CALL:'
15	k	/uri	0	2	Do: $r->notes->{t}=$r->notes->{t}." /uri:after"
20	k	:CALL:	0	0	Do: $r->notes->{t}=$r->notes->{t}." c1"
21	k	:CALL:	0	1	Cond: 0
22	k	:CALL:	0	2	Do: $r->notes->{t}=$r->notes->{t}." c2"
23	k	:CALL:	1	0	Do: $r->notes->{t}=$r->notes->{t}." c3"
24	k	:CALL:	1	1	Do: $r->notes->{t}=$r->notes->{t}." c4"
EOD
update_db;

ok t_cmp GET_BODY( '/uri' ), 'init /uri:before c1 c3 c4 /uri:after /:before c1 c3 c4 /:after', n 'Call';

# LAST als Return in CALL & RESTART
$data=<<'EOD';
#id	xkey	xuri	xblock	xorder	xaction
10	k	/	0	0	Do: $r->notes->{t}=$r->notes->{t}." /:before"
11	k	/	0	1	Call: ':CALL:'
12	k	/	0	2	Do: $r->notes->{t}=$r->notes->{t}." /:after"
13	k	/uri	0	0	Do: $r->notes->{t}=$r->notes->{t}." /uri:before"
14	k	/uri	0	1	Call: ':CALL:'
15	k	/uri	0	2	Do: $r->notes->{t}=$r->notes->{t}." /uri:after"
20	k	:CALL:	0	0	Do: $r->notes->{t}=$r->notes->{t}." c1"
21	k	:CALL:	0	1	Last
22	k	:CALL:	0	2	Do: $r->notes->{t}=$r->notes->{t}." c2"
23	k	:CALL:	1	0	Do: $r->notes->{t}=$r->notes->{t}." c3"
24	k	:CALL:	1	1	Do: $r->notes->{t}=$r->notes->{t}." c4"
30	k	/rstrt	0	0	Do: $r->notes->{t}=$r->notes->{t}." /rstrt"
31	k	/rstrt	0	1	Restart: '/uri'
EOD
update_db;

ok t_cmp GET_BODY( '/uri' ), 'init /uri:before c1 /uri:after /:before c1 /:after', n 'Last as return from Call';
ok t_cmp GET_BODY( '/rstrt' ), 'init /rstrt init /uri:before c1 /uri:after /:before c1 /:after', n 'Restart';

# REDIRECT & ERROR
$data=<<'EOD';
#id	xkey	xuri	xblock	xorder	xaction
10	k	/	0	0	Redirect: 'http://'.join(':', $r->get_server_name, $r->get_server_port).'/redirect1'
11	k	/uri	0	0	Redirect: 'http://'.join(':', $r->get_server_name, $r->get_server_port).'/redirect2', 303
12	k	/error	0	0	Redirect: die "ERROR"
13	k	/404	0	0	Error: 404, 'this appears in the error_log'
EOD
update_db;

my $resp=GET '/';
ok t_cmp $resp->code, 302, n 'Redirect1: code';
ok t_cmp $resp->header('Location'), 'http://'.Apache::TestRequest::hostport.'/redirect1', n 'Redirect1: Location';

$resp=GET '/uri';
ok t_cmp $resp->code, 303, n 'Redirect2: code';
ok t_cmp $resp->header('Location'), 'http://'.Apache::TestRequest::hostport.'/redirect2', n 'Redirect2: Location';

t_client_log_error_is_expected(2);
$resp=GET '/error';
ok t_cmp $resp->code, 500, n 'Redirect error';

t_client_log_error_is_expected();
$resp=GET '/404';
ok t_cmp $resp->code, 404, n 'Error: 404';

# CLIENTIP convenience variable
$data=<<'EOD';
#id	xkey	xuri	xblock	xorder	xaction
10	k	:PRE:	0	0	Do: $r->notes->{t}=$r->notes->{t}." ".$CLIENTIP
EOD
update_db;

ok t_cmp GET_BODY( '/' ), qr/^init \d+\.\d+\.\d+\.\d+$/, n 'CLIENTIP';



$dbh->do('DELETE FROM trans');
$dbh->disconnect;

__END__
# Local Variables: #
# mode: cperl #
# End: #
