use strict;
use warnings FATAL => 'all';

use Apache::Test qw(:withtestmore);
use Apache::TestUtil;
use Test::More;
use Test::Deep;
use DBI;
use DBD::SQLite;
use File::Basename 'dirname';

plan tests=>8;

my $data=<<'EOD';
#id	xkey	xuri		xblock	xorder	xaction
0	k1	u1		0	0	a
1	k1	u1		0	1	b
2	k1	u1		1	0	c
3	k1	u2		0	0	d
4	k1	u2		1	0	e
5	k1	u2		1	1	f
EOD

my $serverroot=Apache::Test::vars->{serverroot};
my ($db,$user,$pw)=@ENV{qw/DB USER PW/};
unless( defined $db and length $db ) {
  ($db,$user,$pw)=("dbi:SQLite:dbname=$serverroot/test.sqlite", '', '');
}
t_debug "Using DB=$db USER=$user";
my $dbh;
sub prepare_db {
  $dbh=DBI->connect( $db, $user, $pw,
		     {AutoCommit=>1, PrintError=>0, RaiseError=>1} )
    or die "ERROR: Cannot connect to $db: $DBI::errstr\n";

  eval {
    $dbh->do( <<'SQL' );
CREATE TABLE cache ( v int )
SQL
  } or $dbh->do( <<'SQL' );
DELETE FROM cache
SQL

  $dbh->do( <<'SQL' );
INSERT INTO cache( v ) VALUES( 1 )
SQL

  eval {
    $dbh->do( <<'SQL' );
CREATE TABLE trans ( id int, xkey text, xuri text, xblock int, xorder int, xaction text )
SQL
  } or $dbh->do( <<'SQL' );
DELETE FROM trans
SQL

  my $stmt=$dbh->prepare( <<'SQL' );
INSERT INTO trans (id, xkey, xuri, xblock, xorder, xaction) VALUES (?,?,?,?,?,?)
SQL

  foreach my $l (grep !/^\s*#/, split /\n/, $data) {
    $stmt->execute(split /\t+/, $l);
  }
}

prepare_db;
sub n {my @c=caller; $c[1].'('.$c[2].'): '.$_[0];}

######################################################################
## the real tests begin here                                        ##
######################################################################

BEGIN{use_ok 'Apache2::Translation::DB'}

my $o=Apache2::Translation::DB->new
  (
   database=>$db, user=>$user, passwd=>$pw,
   table=>'trans', key=>'xkey', uri=>'xuri', block=>'xblock',
   order=>'xorder', action=>'xaction',
   cachesize=>1000, cachetbl=>'cache', cachecol=>'v',
  );

ok $o, n 'provider object';

$o->child_init;
cmp_deeply $o->singleton, 1, n 'is singleton';

$o->start;
cmp_deeply $o->_cache_version, 1, n 'cache version is 1';
$o->stop;

$dbh->do('UPDATE cache SET v=v+1');

$o->start;
cmp_deeply $o->_cache_version, 2, n 'cache version is 2';
cmp_deeply [$o->fetch('k1', 'u1')],
           [['0', '0', 'a'], ['0', '1', 'b'], ['1', '0', 'c']],
           n 'fetch uri u1';
$dbh->do('DELETE FROM trans WHERE id=0');
$dbh->do('UPDATE cache SET v=v+1');
cmp_deeply [$o->fetch('k1', 'u1')],
           [['0', '0', 'a'], ['0', '1', 'b'], ['1', '0', 'c']],
           n 'same result after update';
$o->stop;

$o->start;
cmp_deeply $o->_cache_version, 3, n 'cache version is 3 after another $o->start';
cmp_deeply [$o->fetch('k1', 'u1')],
           [['0', '1', 'b'], ['1', '0', 'c']],
           n 'fetch uri u1 after another $o->start';
$o->stop;

undef $o;
$dbh->disconnect;

__END__
# Local Variables: #
# mode: cperl #
# End: #
