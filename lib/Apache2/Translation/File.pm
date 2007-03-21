package Apache2::Translation::File;

use 5.008;
use strict;
use warnings;
no warnings qw(uninitialized);

use Fcntl qw/:DEFAULT :flock/;
use Class::Member::HASH -CLASS_MEMBERS=>qw/configfile _cache _timestamp/;
our @CLASS_MEMBERS;

our $VERSION = '0.02';

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

  # then override with named parameters
  foreach my $m (@CLASS_MEMBERS) {
    $I->$m=$o{$m} if( exists $o{$m} );
  }

  $I->_cache={};

  return $I;
}

sub _in {
  my ($sym)=@_;

  if( @{*$sym} ) {
    local $"="  ";
    return shift @{*$sym};
  } else {
    return if( ${*$sym} );
    my $l=<$sym>;
    if( defined $l ) {
      return $l;
    } else {
      ${*$sym}=1;
      return;
    }
  }
}

sub _unin {
  my $sym=shift;
  push @{*$sym}, @_;
}

sub start {
  my $I=shift;
  my $time=(stat $I->configfile)[9];

  if( $time!=$I->_timestamp ) {
    $I->_timestamp=$time;
    %{$I->_cache}=();
    open my $f, $I->configfile or do {
      warn( "ERROR: Cannot open translation provider config file: ".
	    $I->configfile.": $!\n" );
      return;
    };
    flock $f, LOCK_SH or die "ERROR: Cannot flock ".$I->configfile.": $!\n";

    my $l;
    my $cache=$I->_cache;
    while( defined( $l=_in $f ) ) {
      chomp $l;
      next if( $l=~/^\s*#/ );	# comment
      $l=~s/^\s*//;
      if( $l=~s!^>>>\s*!! ) {	# new key line found
	my @l=split /\s+/, $l, 5;
	if( @l==5 ) {
	  my $k=join("\0",@l[1,2]);

	  my $a='';
	  while( defined( $l=_in $f ) ) {
	    next if( $l=~/^\s*#/ );	# comment
	    if( $l=~m!^\s*>>>! ) {	# new key line found
	      _unin $f, $l;
	      last;
	    } else {
	      $a.=$l;
	    }
	  }
	  chomp $a;

	  if( exists $cache->{$k} ) {
	    push @{$cache->{$k}}, [@l[3..4],$a,@l[0..2]];
	  } else {
	    $cache->{$k}=[[@l[3..4],$a,@l[0..2]]]
	  }
	}
      }
    }
    close $f;
    foreach my $list (values %{$I->_cache}) {
      @$list=sort {$a->[0] <=> $b->[0] or $a->[1] <=> $b->[1]} @$list;
    }
  }
}

sub stop {}

sub fetch {
  my $I=shift;
  my ($key, $uri)=@_;

  return map {[@{$_}[0..3]]} @{$I->_cache->{join "\0", $key, $uri} || []};
}

sub list_keys {
  my $I=shift;

  my %h;
  foreach my $v (values %{$I->_cache}) {
    $h{$v->[0]->[4]}=1;
  }

  return map {[$_]} sort keys %h;
}

sub list_keys_and_uris {
  my $I=shift;

  if( @_ and length $_[0] ) {
    return sort {$a->[1] cmp $b->[1]}
           map {my @l=split "\0", $_, 2; $l[0] eq $_[0] ? [@l] : ()}
           keys %{$I->_cache};
  } else {
    return sort {$a->[0] cmp $b->[0] or $a->[1] cmp $b->[1]}
           map {[@{$_->[0]}[4,5]]} values %{$I->_cache};
  }
}

sub begin {
}

sub commit {
  my $I=shift;

  my ($w_id, $w_key, $w_uri, $w_blk, $w_ord)=((3)x5);
  foreach my $v (values %{$I->_cache}) {
    foreach my $el (@{$v}) {
      $w_id =length($el->[3]) if( length($el->[3])>$w_id );
      $w_key=length($el->[4]) if( length($el->[4])>$w_id );
      $w_uri=length($el->[5]) if( length($el->[5])>$w_id );
      $w_blk=length($el->[0]) if( length($el->[0])>$w_id );
      $w_ord=length($el->[1]) if( length($el->[1])>$w_id );
    }
  }

  sysopen my $fh, $I->configfile, O_RDWR | O_CREAT or do {
    die "ERROR: Cannot open ".$I->configfile.": $!\n";
  };
  flock $fh, LOCK_EX or die "ERROR: Cannot flock ".$I->configfile.": $!\n";
  my $oldtime=(stat $I->configfile)[9];

  truncate $fh, 0 or
    do {close $fh; die "ERROR: Cannot truncate to ".$I->configfile.": $!\n"};

  my $fmt=">>> %@{[$w_id-1]}s %-${w_key}s %-${w_uri}s %${w_blk}s %${w_ord}s\n";
  printf $fh '#'.$fmt, qw/id key uri blk ord/ or
    do {close $fh; die "ERROR: Cannot write to ".$I->configfile.": $!\n"};
  print $fh "# action\n" or
    do {close $fh; die "ERROR: Cannot write to ".$I->configfile.": $!\n"};

  $fmt=("##################################################################\n".
	">>> %${w_id}s %-${w_key}s %-${w_uri}s %${w_blk}s %${w_ord}s\n%s\n");
  # this sort-thing is not really necessary. It's just to have the saved
  # config file in a particular order for human readability.
  foreach my $v (map {$I->_cache->{$_}} sort keys %{$I->_cache}) {
    foreach my $el (sort {$a->[0] <=> $b->[0] or $a->[1] <=> $b->[1]} @{$v}) {
      printf $fh $fmt, @{$el}[3..5,0..2] or
	do {close $fh; die "ERROR: Cannot write to ".$I->configfile.": $!\n"};
    }
  }

  select( (select( $fh ), $|=1)[0] );  # write buffer

  my $time=time;
  $time=$oldtime+1 if( $time<=$oldtime );

  utime( $time, $time, $I->configfile );
  $I->_timestamp=$time;

  close $fh or die "ERROR: Cannot write to ".$I->configfile.": $!\n";

  return "0 but true";
}

sub rollback {
  my $I=shift;			# reread table
  $I->_timestamp=0;
  $I->start;
}

sub update {
  my $I=shift;
  my $old=shift;
  my $new=shift;

  my $list=$I->_cache->{join "\0", @{$old}[0,1]};
  return "0 but true" unless( $list );
  if( $old->[0] eq $new->[0] and $old->[1] eq $new->[1] ) {
    for( my $i=0; $i<@{$list}; $i++ ) {
      if( $list->[$i]->[3]==$old->[4] and # id
	  $list->[$i]->[0]==$old->[2] and # block
	  $list->[$i]->[1]==$old->[3] ) { # order
	@{$list->[$i]}[0..2]=@{$new}[2..4];
	@{$list}=sort {$a->[0] <=> $b->[0] or $a->[1] <=> $b->[1]} @{$list};
	return 1;
      }
    }
  } else {
    die "ERROR: KEY must not contain spaces.\n" if( $new->[0]=~/\s/ );
    die "ERROR: URI must not contain spaces.\n" if( $new->[1]=~/\s/ );

    for( my $i=0; $i<@{$list}; $i++ ) {
      if( $list->[$i]->[3]==$old->[4] and # id
	  $list->[$i]->[0]==$old->[2] and # block
	  $list->[$i]->[1]==$old->[3] ) { # order
	my ($el)=splice @{$list}, $i, 1;
	delete $I->_cache->{join "\0", @{$old}[0,1]} unless( @{$list} );
	@{$el}[4,5,0..2]=@{$new}[0..4];
	my $k=join("\0",@{$new}[0,1]);
	if( exists $I->_cache->{$k} ) {
	  push @{$I->_cache->{$k}}, $el;
	  $I->_cache->{$k}=[sort {$a->[0] <=> $b->[0] or $a->[1] <=> $b->[1]}
			    @{$I->_cache->{$k}}];
	} else {
	  $I->_cache->{$k}=[$el]
	}
	return 1;
      }
    }
  }
  return "0 but true";
}

sub insert {
  my $I=shift;
  my $new=shift;

  die "ERROR: KEY must not contain spaces.\n" if( $new->[0]=~/\s/ );
  die "ERROR: URI must not contain spaces.\n" if( $new->[1]=~/\s/ );

  my $newid=0;
  foreach my $v (values %{$I->_cache}) {
    foreach my $el (@{$v}) {
      $newid=$el->[3] if( $el->[3]>$newid );
    }
  }
  $newid++;

  my $newel=[@{$new}[2..4], $newid, @{$new}[0,1]];

  my $k=join("\0",@{$new}[0,1]);
  if( exists $I->_cache->{$k} ) {
    push @{$I->_cache->{$k}}, $newel;
    $I->_cache->{$k}=[sort {$a->[0] <=> $b->[0] or $a->[1] <=> $b->[1]}
		      @{$I->_cache->{$k}}];
  } else {
    $I->_cache->{$k}=[$newel];
  }

  return 1;
}

sub delete {
  my $I=shift;
  my $old=shift;

  my $list=$I->_cache->{join "\0", @{$old}[0,1]};
  return "0 but true" unless( $list );

  for( my $i=0; $i<@{$list}; $i++ ) {
    if( $list->[$i]->[3]==$old->[4] and # id
	$list->[$i]->[0]==$old->[2] and # block
	$list->[$i]->[1]==$old->[3] ) { # order
      splice @{$list}, $i, 1;
      delete $I->_cache->{join "\0", @{$old}[0,1]} unless( @{$list} );
      return 1;
    }
  }
  return "0 but true";
}

sub DESTROY {
}

1;
__END__

=head1 NAME

Apache2::Translation::File - A provider for Apache2::Translation

=head1 DESCRIPTION

See L<Apache2::Translation> for more information.

=head1 AUTHOR

Torsten Foertsch, E<lt>torsten.foertsch@gmx.netE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2005-2007 by Torsten Foertsch

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.


=cut
