package Apache2::Translation::Config;

use 5.008;
use strict;
use warnings;
no warnings qw(uninitialized);

use Apache2::RequestRec;
use Apache2::RequestIO;
use Apache2::Module;
use attributes;
use Apache2::Const -compile=>qw{OK};
use YAML ();

sub handler {
  my $r=shift;

  my $cf=Apache2::Module::get_config('Apache2::Translation', $r->server);

  $r->content_type('text/plain');

  my $cache=$cf->{eval_cache};
  if( tied %{$cache} ) {
    $cache=tied( %{$cache} )->max_size;
  } else {
    $cache='unlimited';
  }
  $r->print( YAML::Dump( {
			  TranslationKey=>$cf->{key},
			  TranslationProvider=>$cf->{provider_param},
			  TranslationEvalCache=>$cache,
			 } ) );

  return Apache2::Const::OK;
}

1;
__END__
