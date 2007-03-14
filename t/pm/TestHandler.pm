package TestHandler;

use strict;
use Apache2::RequestRec;
use Apache2::RequestIO;
use Apache2::RequestUtil;
use Apache2::Const -compile=>qw{OK};

sub handler {
  my $r=shift;
  my $class;
  unless( $class=ref $r ) {
    $class=$r;
    $r=shift;
  }
  $r->content_type('text/plain');

  $r->print( $class );

  return Apache2::Const::OK;
}

sub pathinfo {
  my $r=shift;
  $r->content_type('text/plain');

  $r->print( $r->path_info );

  return Apache2::Const::OK;
}

1;
