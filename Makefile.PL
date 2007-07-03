#!perl

use 5.008;
use ModPerl::MM ();
use Apache::TestMM qw(test clean);

# accept the configs from command line
Apache::TestMM::filter_args();
Apache::TestMM::generate_script('t/TEST');

ModPerl::MM::WriteMakefile(
  NAME              => 'Apache2::Translation',
  VERSION_FROM      => 'lib/Apache2/Translation.pm',
  PREREQ_PM         => {
			mod_perl2=>0,
			'Perl::AtEndOfScope'=>0,
			'DBI'=>0,
			'Class::Member'=>1.3,
			'Tie::Cache::LRU'=>0.21,
			'Test::Deep'=>0,
			'Template'=>2.15,
			'Apache2::ModSSL'=>0,
			'YAML'=>0,
		       },
  ABSTRACT_FROM     => 'lib/Apache2/Translation.pod',
  AUTHOR            => 'Torsten Foertsch <torsten.foertsch@gmx.net>',
  dist              => {
			PREOP => './mk_README.sh',
		       },
  clean             => {
			FILES=>"t/TEST",
		       },
);

sub MY::postamble {
  return <<'EOF';
README: lib/Apache2/Translation.pod mk_README.sh
	./mk_README.sh

rpm: dist
	rpmbuild -ba perl-Apache2-Translation.spec
EOF
}
