package Apache2::Translation::DB;

use 5.008;
use strict;
use warnings;
no warnings qw(uninitialized);

use DBI;
use Class::Member::HASH -CLASS_MEMBERS=>qw/database user password table
					   key uri block order action
					   cachesize cachetbl cachecol
					   singleton id is_initialized
					   _cache _cache_version _dbh _stmt/;
our @CLASS_MEMBERS;

our $VERSION = '0.03';

sub new {
  my $parent=shift;
  my $class=ref($parent) || $parent;
  my $I=bless {}=>$class;
  my $x=0;
  my %o=map {($x=!$x) ? lc($_) : $_} @_;

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

sub start {
  my $I=shift;
  unless( $I->_dbh and eval {$I->start_common} ) {
    $I->_dbh->disconnect if( $I->_dbh );
    $I->connect;
    $I->start_common;
  }
}

sub stop {
  my $I=shift;
  undef $I->_stmt;
  undef $I->_dbh if( !$I->singleton and
		     ($I->_dbh->isa( 'Apache::DBI::Cache::db' ) or
		      $I->_dbh->isa( 'Apache::DBI::db' )) );
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
      my ($table_name,$key_col,$uri_col,$block_col,$order_col,$action_col,
	  $id_col)= map {$I->$_} qw/table key uri block order action id/;

      my $sql=<<"SQL";
SELECT $block_col, $order_col, $action_col@{[length $id_col ? ", $id_col" : ""]}
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

sub list_keys {
  my $I=shift;

  my ($table_name,$key_col)=map {$I->$_} qw/table key/;
  my $stmt;
  my $sql=<<"SQL";
SELECT DISTINCT $key_col
FROM $table_name
ORDER BY $key_col ASC
SQL

  $stmt=$I->_dbh->prepare_cached( $sql );
  $stmt->execute;
  return @{$stmt->fetchall_arrayref||[]};
}

sub list_keys_and_uris {
  my $I=shift;

  my ($table_name,$key_col,$uri_col)=map {$I->$_} qw/table key uri/;
  my ($sql, $stmt, @args);
  if( @_ and length $_[0] ) {
    $sql=<<"SQL";
SELECT DISTINCT $key_col, $uri_col
FROM $table_name
WHERE $key_col=?
ORDER BY $key_col ASC, $uri_col ASC
SQL
    push @args, $_[0];
  } else {
    $sql=<<"SQL";
SELECT DISTINCT $key_col, $uri_col
FROM $table_name
ORDER BY $key_col ASC, $uri_col ASC
SQL
  }
  $stmt=$I->_dbh->prepare_cached( $sql );
  $stmt->execute( @args );
  return @{$stmt->fetchall_arrayref||[]};
}

sub begin {
  my $I=shift;
  $I->_dbh->begin_work;
}

sub commit {
  my $I=shift;

  my ($table_name,$col_name)=map {$I->$_} qw/cachetbl cachecol/;
  my $stmt;
  my $sql=<<"SQL";
UPDATE $table_name
SET $col_name=$col_name+1
SQL

  $stmt=$I->_dbh->prepare_cached( $sql );
  $stmt->execute;

  $I->_dbh->commit;
}

sub rollback {
  my $I=shift;
  $I->_dbh->rollback;
}

sub update {
  my $I=shift;
  my $old=shift;
  my $new=shift;

  my ($table_name,$key_col,$uri_col,$block_col,$order_col,$action_col,
      $id_col)= map {$I->$_} qw/table key uri block order action id/;
  my $stmt;
  my $sql=<<"SQL";
UPDATE $table_name
SET $key_col=?,
    $uri_col=?,
    $block_col=?,
    $order_col=?,
    $action_col=?
WHERE $key_col=?
  AND $uri_col=?
  AND $block_col=?
  AND $order_col=?
  AND $id_col=?
SQL

  $stmt=$I->_dbh->prepare_cached( $sql );
  return $stmt->execute( @{$new}[0..4], @{$old}[0..4] );
}

sub insert {
  my $I=shift;
  my $new=shift;

  my ($table_name,$key_col,$uri_col,$block_col,$order_col,$action_col,
      $id_col)= map {$I->$_} qw/table key uri block order action id/;
  my $stmt;
  my $sql=<<"SQL";
INSERT INTO $table_name ($key_col,
                         $uri_col,
                         $block_col,
                         $order_col,
                         $action_col)
VALUES (?, ?, ?, ?, ?)
SQL

  $stmt=$I->_dbh->prepare_cached( $sql );
  return $stmt->execute( @{$new} );
}

sub delete {
  my $I=shift;
  my $old=shift;

  my ($table_name,$key_col,$uri_col,$block_col,$order_col,$action_col,
      $id_col)= map {$I->$_} qw/table key uri block order action id/;
  my $stmt;
  my $sql=<<"SQL";
DELETE FROM $table_name
WHERE $key_col=?
  AND $uri_col=?
  AND $block_col=?
  AND $order_col=?
  AND $id_col=?
SQL

  $stmt=$I->_dbh->prepare_cached( $sql );
  return $stmt->execute( @{$old} );
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

=head1 NAME

Apache2::Translation::DB - A provider for Apache2::Translation

=head1 DESCRIPTION

See L<Apache2::Translation> for more information.

=head1 AUTHOR

Torsten Foertsch, E<lt>torsten.foertsch@gmx.netE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2005-2007 by Torsten Foertsch

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.


=cut
