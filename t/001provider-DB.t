use strict;
use warnings FATAL => 'all';

use Apache::Test qw(:withtestmore);
use Apache::TestUtil;
use Test::More;
use Test::Deep;
use DBI;
use DBD::SQLite;
use File::Basename 'dirname';

plan tests=>17;
#plan 'no_plan';

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
CREATE TABLE trans ( id int, xkey text, xuri text, xblock int, xorder int, xaction text, xnotes text )
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

  eval {
    $dbh->do( <<'SQL' );
CREATE TABLE sequences ( xname text, xvalue int )
SQL
  } or $dbh->do( <<'SQL' );
DELETE FROM sequences WHERE xname='id'
SQL
}

prepare_db;
sub n {my @c=caller; $c[1].'('.$c[2].'): '.$_[0];}

######################################################################
## the real tests begin here                                        ##
######################################################################

use Apache2::Translation::DB;

my $o=Apache2::Translation::DB->new
  (
   Database=>$db, User=>$user, Passwd=>$pw,
   Table=>'trans', Key=>'xkey', Uri=>'xuri', Block=>'xblock',
   Order=>'xorder', Action=>'xaction', Id=>'id',
   CacheSize=>1000, CacheTbl=>'cache', CacheCol=>'v',
  );

ok $o, n 'provider object';

ok tied(%{$o->_cache}), n 'tied cache';

$o->start;
cmp_deeply $o->_cache_version, 1, n 'cache version is 1';
$o->stop;

$dbh->do('UPDATE cache SET v=v+1');

$o->start;
cmp_deeply $o->_cache_version, 2, n 'cache version is 2';
cmp_deeply [$o->fetch('k1', 'u1')],
           [['0', '0', 'a', '0'], ['0', '1', 'b', '1'], ['1', '0', 'c', '2']],
           n 'fetch uri u1';
$dbh->do('DELETE FROM trans WHERE id=0');
$dbh->do('UPDATE cache SET v=v+1');
cmp_deeply [$o->fetch('k1', 'u1')],
           [['0', '0', 'a', '0'], ['0', '1', 'b', '1'], ['1', '0', 'c', '2']],
           n 'same result after update';
$o->stop;

$o->id=undef;	       	# check that no id is delivered if this is unset
$o->start;
cmp_deeply $o->_cache_version, 3, n 'cache version is 3 after another $o->start';
cmp_deeply [$o->fetch('k1', 'u1')],
           [['0', '1', 'b'], ['1', '0', 'c']],
           n 'fetch uri u1 after another $o->start';
cmp_deeply [$o->fetch('unknown', 'unknown')], [],
           n 'fetch unknown key/uri pair';
cmp_deeply exists( $o->_cache->{"unknown\0unknown"} )||0, 0,
           n 'cache state after fetching unknown key/uri pair';
$o->stop;

$o=Apache2::Translation::DB->new
  (
   Database=>$db, User=>$user, Passwd=>$pw,
   Table=>'trans', Key=>'xkey', Uri=>'xuri', Block=>'xblock',
   Order=>'xorder', Action=>'xaction', Id=>'id', Notes=>'xnotes',
   CacheSize=>1000, CacheTbl=>'cache', CacheCol=>'v',
   SeqTbl=>'sequences', SeqNameCol=>'xname', SeqValCol=>'xvalue',
   IdSeqName=>'id',
  );

$o->start;
cmp_deeply [$o->fetch('k1', 'u1', 1)],
           [['0', '1', 'b', '1', ''], ['1', '0', 'c', '2', '']],
           n 'fetch with notes';

$o->begin;
$o->update( ["k1", "u1", 1, 0, 2],
	    ["k1", "u1", 1, 2, "new action", 'note on 2'] );
$o->commit;

cmp_deeply [$o->fetch('k1', 'u1', 1)],
           [['0', '1', 'b', '1', ''], ['1', '2', 'new action', '2', 'note on 2']],
           n 'fetch changed notes';

eval {
  $o->begin;
  $o->insert([qw/k2 u1 1 2 inserted_action a_note/]);
  $o->commit;
} or $o->rollback;
cmp_deeply $@, "ERROR: sequences table not set up: missing row with xname=id\n",
           n 'sequences table not set up';

$dbh->do( <<'SQL' );
INSERT INTO sequences (xname, xvalue) VALUES ('id', 10)
SQL

eval {
  $o->begin;
  $o->insert([qw/k2 u1 1 2 inserted_action a_note/]);
  $o->commit;
};
cmp_deeply $@, '', n 'sequences table set up';

cmp_deeply [$o->fetch('k2', 'u1', 1)],
           [['1', '2', 'inserted_action', '10', 'a_note']],
           n 'fetch with notes';

cmp_deeply [$o->dump],
           [['k1', 'u1', '0', '1', 'b', ''],
	    ['k1', 'u1', '1', '2', 'new action', 'note on 2'],
	    ['k1', 'u2', '0', '0', 'd', ''],
	    ['k1', 'u2', '1', '0', 'e', ''],
	    ['k1', 'u2', '1', '1', 'f', ''],
	    ['k2', 'u1', '1', '2', 'inserted_action', 'a_note']
	   ],
           n 'dump';

$o->restore(['k2', 'u1', '2', '0', 'restored_1', 'note_1'],
	    ['k2', 'u1', '2', '1', 'restored_2', 'note_2']);

cmp_deeply [$o->fetch('k2', 'u1', 1)],
           [['1', '2', 'inserted_action', '10', 'a_note'],
	    ['2', '0', 'restored_1', '11', 'note_1'],
	    ['2', '1', 'restored_2', '12', 'note_2']],
           n 'fetch after restore';


$o->stop;

undef $o;

$dbh->disconnect;

__END__
# Local Variables: #
# mode: cperl #
# End: #
