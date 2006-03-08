package Apache2::Translation::DB;

use 5.008;
use strict;
use warnings;
no warnings qw(uninitialized);

use DBI;
use Class::Member::HASH -CLASS_MEMBERS=>qw/database user password table
					   key uri block order action
					   cachesize cachetbl cachecol
					   singleton
					   _cache _cache_version _dbh _stmt/;
our @CLASS_MEMBERS;

our $VERSION = '0.02';

sub new {
  my $parent=shift;
  my $class=ref($parent) || $parent;
  my $I=bless {}=>$class;
  my %o=@_;

  if( ref($parent) ) {         # inherit first
    foreach my $m (@CLASS_MEMBERS) {
      $I->$m=$parent->$m;
    }
  }

  $I->cachesize=1000;
  $I->singleton=0;

  # then override with named parameters
  foreach my $m (@CLASS_MEMBERS) {
    $I->$m=$o{$m} if( exists $o{$m} );
  }

  $I->_cache={};
  if( $I->cachesize=~/^\d/ ) {
    eval "use Tie::Cache::LRU";
    die "$@" if $@;
    tie %{$I->_cache}, 'Tie::Cache::LRU', $I->cachesize;
  }

  return $I;
}

sub connect {
  my $I=shift;

  return $I->_dbh=DBI->connect( $I->database, $I->user, $I->password,
				{
				 AutoCommit=>1,
				 PrintError=>0,
				 RaiseError=>1,
				} );
}

sub child_init {
  my $I=shift;

  *start=\&start_singleton;
  *stop=\&stop_singleton;

  $I->connect;
  if( !$I->singleton and
      ($I->_dbh->isa( 'Apache::DBI::Cache::db' ) or
       $I->_dbh->isa( 'Apache::DBI::db' )) ) {
    no warnings 'redefine';
    *start=\&start_cached;
    *stop=\&stop_cached;
    $I->_dbh->disconnect;
    undef $I->_dbh;
    $I->singleton=0;
  } else {
    $I->singleton=1;
  }
}

sub start_cached {
  my $I=shift;
  $I->connect;
  $I->start_common;
}

sub stop_cached {
  my $I=shift;
  undef $I->_stmt;
  undef $I->_dbh;
}

sub start_singleton {
  my $I=shift;
  unless( eval {$I->start_common} ) {
    $I->_dbh->disconnect if( $I->_dbh );
    $I->connect;
    $I->start_common;
  }
}

sub stop_singleton {
  my $I=shift;
  undef $I->_stmt;
}

sub start_common {
  my $I=shift;

  my ($cache_tbl,$cache_col)=map {$I->$_} qw/cachetbl cachecol/;

  my $sql=<<"SQL";
SELECT MAX($cache_col)
FROM $cache_tbl
SQL

  my $stmt=$I->_dbh->prepare_cached( $sql );
  $stmt->execute;
  my $cache_version=$stmt->fetchall_arrayref->[0]->[0];

  unless( $cache_version eq $I->_cache_version ) {
    %{$I->_cache}=();
    $I->_cache_version=$cache_version;
  }

  return 1;
}

sub fetch {
  my $I=shift;
  my ($key, $uri)=@_;

  my $ref=$I->_cache->{"$key\0$uri"};

  unless( defined $ref ) {
    unless( defined $I->_stmt ) {
      my ($table_name,$key_col,$uri_col,$block_col,$order_col,$action_col)=
	map {$I->$_} qw/table key uri block order action/;

      my $sql=<<"SQL";
SELECT $block_col, $order_col, $action_col
FROM $table_name
WHERE $key_col=?
  AND $uri_col=?
ORDER BY $block_col ASC, $order_col ASC
SQL

      $I->_stmt=$I->_dbh->prepare_cached( $sql );
    }

    $I->_stmt->execute( $key, $uri );
    $ref=$I->_stmt->fetchall_arrayref||[];

    $I->_cache->{"$key\0$uri"}=$ref;
  }

  return @{$ref};
}

sub DESTROY {
  my $I=shift;
  if( defined $I->_dbh ) {
    $I->_dbh->disconnect;
    undef $I->_dbh;
  }
}

1;
__END__
