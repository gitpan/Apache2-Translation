#!/bin/bash

perl -pe '/^=head1 DESCRIPTION/ and print <STDIN>' lib/Apache2/Translation.pod >README.pod <<EOF
=head1 INSTALLATION

 perl Makefile.PL
 make
 make test
 make install

=head1 DEPENDENCIES

=over 4

=item mod_perl2: 2.0.2

=item recommended patch:
http://www.gossamer-threads.com/lists/modperl/modperl/87487#87487

=back

EOF

perldoc -tU README.pod >README
rm README.pod