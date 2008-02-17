package Apache2::Translation::_base;

use 5.8.8;
use strict;
use warnings;
no warnings qw(uninitialized);

our $VERSION = '0.01';

use constant {
  BLOCK   => 0, 		# \
  ORDER   => 1, 		#  |
  ACTION  => 2,			#  |
  ID      => 3,			#   \ used for internal
  KEY     => 4,			#   / storage
  URI     => 5,			#  |
  NOTE    => 6,			# /

  nKEY    => 0,			# \
  nURI    => 1,			#  |
  nBLOCK  => 2,			#   \ used when updating an element or
  nORDER  => 3,			#   / inserting a new one as $new
  nACTION => 4,			#  |
  nNOTE   => 5,			#  |
  nID     => 6,			# /  # only used in iterator

  oKEY    => 0,			# \
  oURI    => 1,			#  |
  oBLOCK  => 2,			#   \ used when updating an element or
  oORDER  => 3,			#   / deleting one as $old
  oID     => 4,			#  /
};

sub import {
  my $mod=caller;
  no strict 'refs';
  *{$mod."::KEY"}    = \&KEY;
  *{$mod."::URI"}    = \&URI;
  *{$mod."::BLOCK"}  = \&BLOCK;
  *{$mod."::ORDER"}  = \&ORDER;
  *{$mod."::ACTION"} = \&ACTION;
  *{$mod."::NOTE"}   = \&NOTE;
  *{$mod."::ID"}     = \&ID;

  *{$mod."::nKEY"}    = \&nKEY;
  *{$mod."::nURI"}    = \&nURI;
  *{$mod."::nBLOCK"}  = \&nBLOCK;
  *{$mod."::nORDER"}  = \&nORDER;
  *{$mod."::nACTION"} = \&nACTION;
  *{$mod."::nNOTE"}   = \&nNOTE;
  *{$mod."::nID"}     = \&nID;

  *{$mod."::oKEY"}    = \&oKEY;
  *{$mod."::oURI"}    = \&oURI;
  *{$mod."::oBLOCK"}  = \&oBLOCK;
  *{$mod."::oORDER"}  = \&oORDER;
  *{$mod."::oID"}     = \&oID;
}

sub append {
  my ($I, $other)=@_;

  my $rc=0;
  my $iterator=$other->iterator;
  while( my $el=$iterator->() ) {
    $rc+=$I->insert($el);
  }
  return $rc;
}

sub _expand {
  my ($el, $prefix, $what)=@_;

  my $val=$el->[eval "n$what"];
  while( $prefix=~/(p|s)(.*?);/g ) {
    my ($op, $arg)=($1, $2);
    if( $op eq 'p' ) {
      $val=~s/\s*\z//;
      if( defined $arg ) {
	$val=~s/\r?\n/\n$arg/g;
	substr( $val, 0, 0 )=$arg;
      } else {
	$val=~s/\r?\n//g;
      }
    } elsif( $op eq 's' ) {
      if( $arg eq 'l' ) {
	$val=~s/\A\s*//;
      } else {
	$val=~s/\s*\z//;
      }
    }
  }
  return $val;
}

my $default_fmt=<<'EOF';
######################################################################
%{KEY} & %{URI} %{BLOCK}/%{ORDER}/%{ID}
%{paction> ;ACTION}
%{pnote> ;NOTE}
EOF

sub dump {
  my ($I, $fmt, $fh)=@_;

  $fmt=$default_fmt unless( length $fmt );
  $fh=\*STDOUT unless( ref($fh) );
  my $iterator=$I->iterator;
  while( my $el=$iterator->() ) {
    my $x=$fmt;
    $x=~s/%{(.*?)(KEY|URI|BLOCK|ORDER|ACTION|NOTE|ID)}/_expand($el,$1,$2)/gse;
    print $fh $x;
  }
}

sub DESTROY {}

1;
__END__
