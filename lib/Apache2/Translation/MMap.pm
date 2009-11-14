package Apache2::Translation::MMap;

use 5.008008;
use strict;
use integer;
use bytes;

# filename and readonly are public; root is semipublic in a sense that it's
# used to pass ServerRoot by Apache2::Translation.
# _data holds a reference to the mmapped area.
# _tmpfh, _idmap and _minfreeid are used only within a begin/commit
# cycle. _tmpfh is the filehandle of the new file. _idmap maps IDs to
# positions in the *new* file. For more information about _minfreeid
# see begin() below.
use Class::Member::HASH -CLASS_MEMBERS=>qw/filename readonly root
					   _data _tmpfh _idmap _minfreeid
					   _keyindex/;
our @CLASS_MEMBERS;

use Fcntl qw/:seek :flock/;
use File::Spec;
use Sys::Mmap::Simple 'map_file';
use Apache2::Translation::_base;
use base 'Apache2::Translation::_base';

use warnings;
no warnings qw(uninitialized);

our $VERSION = '0.01';

BEGIN {
  use constant {
    MAGICNUMBER   => 'ATMM',
    FORMATVERSION => 0,		# magic number position
    DATAVALID     => 4,		# valid byte position
      # 3 bytes gap
    INDEXPOS      => 8,
    DATASTART     => 12,
  };
}

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

  return $I;
}

sub _fname {
  my ($I)=@_;

  my $fname=$I->filename;
  if( length $I->root ) {
    unless( File::Spec->file_name_is_absolute($fname) ) {
      $fname=File::Spec->catfile( $I->root, $fname );
    }
  }
  return $fname;
}

sub start {
  my ($I)=@_;

  if( $I->_data ) {
    #warn "start: have _data\n";
    undef $I->_data unless( substr( ${$I->_data}, DATAVALID, 1 ) eq '1' );
  }

  unless( $I->_data ) {
    #warn "start: no _data ==> connecting\n";
    my $dummy;
    eval {map_file $dummy, $I->_fname, ($I->readonly ? '<' : '+<')};
    return if $@;
    return unless length $dummy;
    return unless substr($dummy, FORMATVERSION, 4) eq MAGICNUMBER;
    return unless substr( $dummy, DATAVALID, 1 ) eq '1';
    $I->_data=\$dummy;		# now mapped
    #warn "mapped: ".length($dummy)." bytes\n";

    $I->_keyindex=unpack 'x'.INDEXPOS.'N', ${$I->_data};
  }
}

sub stop {}

sub fetch {
  my $I=shift;
  my ($key, $uri, $with_notes)=@_;

  my $el=$I->_index_lookup($I->_keyindex, $key);
  return unless $el;

  $el=$I->_index_lookup($el->[1], $uri);
  return unless $el;

  warn "found: @$el\n";
}

=secret

  # cache element:
  # [block, order, action, id, note]
  if( $with_notes and length $I->notesdir ) {
    # return element:
    # [block order, action, id, notes]
    local $/;
    return map {[@{$_}[BLOCK,ORDER,ACTION,ID], $I->_getnote($_->[ID])]}
               @{$I->_cache->{join "\0", $key, $uri} || []};
  } else {
    # return element:
    # [block order, action, id]
    return map {[@{$_}[BLOCK,ORDER,ACTION,ID]]}
           @{$I->_cache->{join "\0", $key, $uri} || []};
  }

=cut

sub can_notes {1}

sub _index_iterator {
  my ($I, $pos)=@_;

  my $data=$I->_data;
  my ($nrecords, $recordlen)=unpack 'x'.$pos.'N2', $$data;
  my ($cur, $end)=($pos+8, $pos+8+$nrecords*$recordlen);
  return sub {
    return if $cur>=$end;
    my @el=unpack 'x'.$cur.'N/a*N/(N)*', $$data;
    $cur+=$recordlen;
    return [@el];
  };
}

sub _index_lookup {
  my ($I, $pos, $key)=@_;

  warn "Index Lookup: $key\n";
  my $data=$I->_data;
  my ($nrecords, $recordlen)=unpack 'x'.$pos.'N2', $$data;

  my ($low, $high)=(0, $nrecords);
  my ($cur, $rel, @el);
  while( $low<$high ) {
    $cur=($high+$low)/2;	# "use integer" is active, see above
    @el=unpack 'x'.($cur*$recordlen+$pos+8).'N/a*N/(N)*', $$data;
    warn "  --> looking at $el[0]: low=$low, high=$high, cur=$cur\n";
    $rel=($el[0] cmp $key);
    if( $rel<0 ) {
      warn "  --> moving low: $low ==> ".($cur+1)."\n";
      $low=$cur+1;
    } elsif( $rel>0 ) {
      warn "  --> moving high: $high ==> ".($cur)."\n";
      # don't try to optimize here: $high=$cur-1 will not work in border cases
      $high=$cur;
    } else {
      warn "  --> BINGO\n";
      return [@el];
    }
  }
  warn "  --> NOT FOUND\n";
  return $rel ? () : [@el];
}

sub list_keys {
  my ($I)=@_;

  my $keyindex=unpack 'x'.INDEXPOS.'N', ${$I->_data};
  my @list;

  for( my $it=$I->_index_iterator($keyindex); my $el=$it->(); ) {
    use Data::Dumper; local $Data::Dumper::Useqq=1;
    warn Dumper($el);
    push @list, [$el->[0]];
  }

  return @list;
}

sub list_keys_and_uris {
  my ($I, $key)=@_;

  my @list;

  if( @_>1 and length $key ) {
    my $el=$I->_index_lookup($I->_keyindex, $key);
    return unless $el;

    for( my $it=$I->_index_iterator($el->[1]); $el=$it->(); ) {
      #use Data::Dumper; local $Data::Dumper::Useqq=1;
      #warn Dumper($el);
      push @list, [$key, $el->[0]];
    }
  } else {
    for( my $kit=$I->_index_iterator($I->_keyindex); my $kel=$kit->(); ) {
      for( my $it=$I->_index_iterator($kel->[1]); my $el=$it->(); ) {
	#use Data::Dumper; local $Data::Dumper::Useqq=1;
	#warn Dumper($el);
	push @list, [$kel->[0], $el->[0]];
      }
    }
  }

  return @list;
}

sub _tmpfname {
  my ($I)=@_;

  return $I->_fname.".$$";
}

sub _fmt_entry {
  my ($I, $el)=@_;

  # el format: [key, uri, block, order, action, note, id]

  # pack format: valid key uri block order action note id
  return pack('C(N/a*)2N2(N/a*)2N', 1, @$el);
}

sub _dec_entry {
  my ($I, $string)=@_;

  # pack format: valid id key uri block order action note id
  return unpack('C(N/a*)2N2(N/a*)2N', $string);
}

sub begin {
  my ($I)=@_;

  die "Read-Only mode\n" if $I->readonly;

  # XXX: implement locking over begin/commit

  # open tmpfile
  undef $I->_tmpfh;		# to be sure
  open my $fh, '+>', $I->_tmpfname or
    die "Cannot open ".$I->_tmpfname.": $!\n";
  $I->_tmpfh=$fh;

  syswrite $fh, pack('a4ax3N',
		     MAGICNUMBER,
		     1,	# DATAVALID
		     -1	# INDEXPOS (no index)
		    )
    or die "Cannot write ".$I->_tmpfname.": $!\n";

  # and copy every *valid* entry from the old file
  # create _idmap on the way
  $I->_idmap=my $idmap={};
  my $freeid=1;
  for( my $it=$I->iterator; my $el=$it->(); ) {
    $I->insert($el);
    if( $el->[nID]==$freeid ) {
      # ok that id is in use. so, let's look for the next one
      1 while exists $idmap->{++$freeid};
    }
  }
  # minfreeid always contains the lowest free ID. It is updated in delete()
  # if the deleted element's ID is lower and in insert() obviously. This way
  # an insert operation does not have to scan the whole idmap for a free id
  # and the whole thing becomes almost O(1).
  $I->_minfreeid=$freeid;
}

# The interator() below hops over the mmapped area. This one works on the file.
# It can be used only within a begin/commit cycle.
sub _fiterator {
  my ($I)=@_;

  my $fh=$I->_tmpfh;
  my $pos=DATASTART;
  my $end=do {
    sysseek $fh, INDEXPOS, SEEK_SET or die "sysseek failed: $!\n";
    my $buf;
    sysread($fh, $buf, 4)==4 or die "sysread failed: $!\n";
    unpack 'N', $buf;
  };

  return sub {
  LOOP: {
      #warn "_fiterator: POS: $pos\n";
      return if $pos>=$end;

      sysseek $fh, $pos, SEEK_SET or die "sysseek failed: $!\n";
      my $buf;
      sysread($fh, $buf, 4)==4 or die "sysread failed: $!\n";
      my $len=unpack 'N', $buf;
      sysread($fh, $buf, $len)==$len or die "sysread failed: $!\n";
      my $elpos=$pos;
      $pos+=4+$len;

      my ($valid, @el)=$I->_dec_entry($buf);

      #warn "  -->".($valid?"":" invalid")." el=@el\n";

      return ([@el], $elpos) if $valid;
      redo LOOP;
    }
  };
}

sub __index_record_len {
  #use Data::Dumper; local $Data::Dumper::Useqq=1;
  my $max=0;
  while( my ($k, $v)=splice @_, 0, 2 ) {
    my $s=pack 'N/a*N/(N)*', $k, @$v;
    #warn "$k, @$v\n  ", Dumper($s);
    $max=length($s) if length($s)>$max;
  }
  #warn "max=$max\n";
  return $max;
}

sub _really_write_index {
  my ($I, $map)=@_;

  my $fh=$I->_tmpfh;
  my $recordlen=__index_record_len(map {($_=>$map->{$_})} keys %$map);

  my $pos=sysseek $fh, 0, SEEK_CUR; # this should be named systell
  die "sysseek failed: $!\n" unless defined $pos;

  warn "  --> recordlen=$recordlen, nrecords=".(keys %$map)."\n";

  # write header
  syswrite $fh, pack('N2', scalar(keys %$map), $recordlen)
    or die "Cannot write ".$I->_tmpfname.": $!\n";

  # write the records
  $recordlen='a'.$recordlen;
  foreach my $key (sort keys %$map) {
    use Data::Dumper; local $Data::Dumper::Useqq=1;
    warn("  --> record: ".
	 Dumper(pack($recordlen,
		     pack('N/a*N/(N)*', $key, @{$map->{$key}}))));
    syswrite $fh, pack($recordlen,
		       pack('N/a*N/(N)*', $key, @{$map->{$key}}))
      or die "Cannot write ".$I->_tmpfname.": $!\n";
  }

  return $pos;
}

sub _write_index {
  my ($I)=@_;

  my %map;
  for( my $it=$I->_fiterator; my ($el, $pos)=$it->(); ) {
    push @{$map{$el->[nKEY]}->{$el->[nURI]}}, [@{$el}[nBLOCK, nORDER], $pos];
  }

  my $fh=$I->_tmpfh;
  my $indexpos=do {
    sysseek $fh, INDEXPOS, SEEK_SET or die "sysseek failed: $!\n";
    my $buf;
    sysread($fh, $buf, 4)==4 or die "sysread failed: $!\n";
    unpack 'N', $buf;
  };

  # first write out all URI indices
  # but leave space for the KEY index
  my $keyindexsize=(8 +		# nelem + elemlen
		    __index_record_len(map {($_=>[0])} keys %map)*keys(%map));

  sysseek $fh, $indexpos+$keyindexsize, SEEK_SET or die "sysseek failed: $!\n";
  foreach my $key (keys %map) {
    # order blocklist
    foreach my $v (values %{$map{$key}}) {
      $v=[map {$_->[2]} sort {$a->[0]<=>$b->[0] or $a->[1]<=>$b->[1]} @$v];
    }
    warn "writing $key index\n";
    $map{$key}=[$I->_really_write_index($map{$key})];
    warn "$key index done at position $map{$key}->[0]\n";
  }

  # no write the KEY index
  sysseek $fh, $indexpos, SEEK_SET or die "sysseek failed: $!\n";
  warn "writing KEY index at $indexpos\n";
  $I->_really_write_index(\%map);
  warn "KEY index done\n";
  sysseek $fh, 0, SEEK_END or die "sysseek failed: $!\n";
}

sub commit {
  my ($I)=@_;

  my $indexpos=sysseek $I->_tmpfh, 0, SEEK_CUR; # this should be named systell
  die "sysseek failed: $!\n" unless $indexpos;

  sysseek $I->_tmpfh, INDEXPOS, SEEK_SET
    or die "sysseek failed: $!\n";

  syswrite $I->_tmpfh, pack('N', $indexpos)
    or die "Cannot write ".$I->_tmpfname.": $!\n";

  sysseek $I->_tmpfh, $indexpos, SEEK_SET
    or die "sysseek failed: $!\n";

  # compute index
  $I->_write_index;
  close $I->_tmpfh or die "While closing ".$I->_tmpfname.": $!\n";
  undef $I->_tmpfh;
  undef $I->_idmap;

  # rename is (at least on Linux) an atomic operation
  rename $I->_tmpfname, $I->_fname or
    die "Cannot rename ".$I->_tmpfname." to ".$I->_fname.": $!\n";

  if( $I->_data ) {
    substr( ${$I->_data}, DATAVALID, 1 )='0'; # invalidate current map
  }

  $I->start;
}

sub rollback {
  my ($I)=@_;

  close $I->_tmpfh;
  undef $I->_tmpfh;
  undef $I->_idmap;
  unlink $I->_tmpfname;
}

sub update {
  my $I=shift;
  my $old=shift;
  my $new=shift;

  return $I->insert($new) if $I->delete($old)>0;
  return "0 but true";
}

sub insert {
  my $I=shift;
  my $new=shift;

  #warn "insert: new=@$new\n";

  # create new ID if necessary
  my $idmap=$I->_idmap;
  if( defined $new->[nID] ) {
    die "Can't insert the same ID ($new->[nID]) twice\n"
      if exists $idmap->{$new->[nID]};
  } else {
    my $freeid=$I->_minfreeid;
    $new->[nID]=$freeid;
    1 while exists $idmap->{++$freeid};
    $I->_minfreeid=$freeid;
  }

  my $fh=$I->_tmpfh;

  my $pos=sysseek $fh, 0, SEEK_CUR; # this should be named systell
  die "sysseek failed: $!\n" unless $pos;

  syswrite $fh, pack('N/a*', $I->_fmt_entry( $new ))
    or die "Cannot write ".$I->_tmpfname.": $!\n";

  $idmap->{$new->[nID]}=$pos;

  return $pos;
}

sub delete {
  my $I=shift;
  my $old=shift;

  #warn "delete: old=@$old\n";

  # no such id
  return "0 but true" unless exists $I->_idmap->{$old->[oID]};

  my $fh=$I->_tmpfh;
  my $idmap=$I->_idmap;
  my $oldid=$old->[oID];
  my $pos=$idmap->{$oldid};

  sysseek $fh, $pos, SEEK_SET or die "sysseek failed: $!\n";

  my $buf;
  sysread($fh, $buf, 4)==4 or die "sysread failed: $!\n";
  my $len=unpack 'N', $buf;
  sysread($fh, $buf, $len)==$len or die "sysread failed: $!\n";
  my ($valid, @el)=$I->_dec_entry($buf);

  #warn "  --> el=@el\n";

  my $rc="0 but true";
  if( $valid                        and
      $el[nID]    == $oldid         and
      $el[nKEY]   eq $old->[oKEY]   and
      $el[nURI]   eq $old->[oURI]   and
      $el[nBLOCK] == $old->[oBLOCK] and
      $el[nORDER] == $old->[oORDER] ) {
    sysseek $fh, $pos+4, SEEK_SET or die "sysseek failed: $!\n";
    syswrite $fh, "\0" or die "Cannot write ".$I->_tmpfname.": $!\n";
    sysseek $fh, 0, SEEK_END or die "sysseek failed: $!\n";
    $I->_minfreeid=$oldid if $I->_minfreeid<$oldid;
    $rc=1;
  }

  sysseek $fh, 0, SEEK_END or die "sysseek failed: $!\n";
  return $rc;
}

sub clear {
  my ($I)=@_;

  my $fh=$I->_tmpfh;
  sysseek $fh, DATASTART, SEEK_SET or die "sysseek failed: $!\n";
  truncate $fh, DATASTART or die "truncate failed: $!\n";
  $I->_idmap={};
  $I->_minfreeid=1;

  return "0 but true";
}

sub iterator {
  my ($I, $show_invalid)=@_;

  my $data=$I->_data;
  return sub{} unless $data;

  my $pos=DATASTART;
  my $end=$I->_keyindex;

  return sub {
  LOOP: {
      #warn "POS: $pos\n";
      return if $pos>=$end;
      my $string=unpack 'x'.$pos.'N/a*', $$data;
      my $original_pos=$pos;
      $pos+=4+length($string);

      # pack format: valid key uri block order action note id

      my ($valid, @el)=$I->_dec_entry($string);
      if ($valid or $show_invalid) {
	return wantarray ? ([@el], $original_pos, $valid) : [@el];
      }
      redo LOOP;
    }
  };
}

1;
__END__

=head1 DISK LAYOUT

All lengths, offsets and other numbers are in unsigned long big-endian
format (pack C<N>).

=head2 Descriptor

At start comes a 12 byte descriptor:

 +----------------------------------+
 | MAGIC NUMBER (4 bytes) == 'ATMM' |
 +----------------------------------+
 | VALID (1 byte) + 3 bytes reservd |
 +----------------------------------+
 | INDEX POSITION (4 bytes)         |
 +----------------------------------+

The magic number always contains the string C<ATMM>. The C<VALID> byte
contains either C<1> (byte C<\x31>) or something else (C<0>). C<1> means
the file is valid. C<start()> checks this flag and remaps the file if it
is not C<1>. C<commit()> writes C<0> to it after the new file is completely
written and successfully renamed to the original name. Thus C<start()> gives
up the out-of-date data and maps the new.

L<Index position/The Index> is the file position just after the actual data.

=head2 Data Records

Just after the descriptor at file position C<12> follows an arbitrary
number of data records. Each record is laid out this way:

 +----------------------------------+
 | record length (4 bytes)          |                 \
 +----------------------------------+                  \
 | valid (1 byte)                   | pack 'C'         |
 +----------------------------------+                  |
 | key length (4 bytes)             | \                |
 +----------------------------------+  > pack 'N/a*'   |
 | key (arbitrary number of bytes)  | /                |
 +----------------------------------+                  |
 | uri length (4 bytes)             | \                |
 +----------------------------------+  > pack 'N/a*'   |
 | uri (arbitrary number of bytes)  | /                |
 +----------------------------------+                  |
 | block (4 bytes)                  | pack 'N'          > pack 'N/a*'
 +----------------------------------+                  |
 | order (4 bytes)                  | pack 'N'         |
 +----------------------------------+                  |
 | action length (4 bytes)          | \                |
 +----------------------------------+  > pack 'N/a*'   |
 | action (arbit. number of bytes)  | /                |
 +----------------------------------+                  |
 | note length (4 bytes)            | \                |
 +----------------------------------+  > pack 'N/a*'   |
 | note (arbitrary number of bytes) | /                |
 +----------------------------------+                  /
 | id (4 bytes)                     | pack 'N'        /
 +----------------------------------+

Note that strings of arbitrary length are always encoded in C<N/a*> pack
format. That means the length field does not count the 4 bytes for the
length field itself. Thus, C<abc> will be encoded as C<3 abc> not C<7 abc>.

The C<valid> byte specifies if the record itself is valid. It contains
a binary C<\x00> if not so. An invalid record is practically a hole in the
file. It is the result of a C<delete> or C<update> operation.

All other fields are self-explanatory.

=head2 The Index

Just after the data section follows the I<KEY> index. Its starting position
is part of the descriptor block. Then follows an arbitrary number of I<URI>
indices.

An index is mainly an ordered list of strings each of which points to a
list of file positions. In case of the KEY index this list contains always one
element, the position of its URI index. For an URI index the list contains
the ordered block list element positions.

An index starts with a short header consisting of 2 numbers followed by
constant length index records:

 +----------------------------------+
 | NRECORDS (4 bytes)               |
 +----------------------------------+
 | RECORDLEN (4 bytes)              |
 +----------------------------------+
 ¦                                  ¦
 ¦ constant length records          ¦
 ¦                                  ¦
 +----------------------------------+

Each record is laid out this way:

 +----------------------------------+
 | string length                    | \
 +----------------------------------+  > pack 'N/a*'
 | string (arbit. number of bytes)  | /
 +----------------------------------+
 | number of positions              | \
 +----------------------------------+  > pack 'N/N*'
 | positions                        | /
 +----------------------------------+
 ¦                                  ¦
 ¦ padding up to RECORDLEN          ¦
 ¦                                  ¦
 +----------------------------------+

C<RECORDLEN> is computed for each index to fit for the longest string and
position list.

=cut

