use Geo::Geometry;

use NativeCall;
sub mmap(Pointer $addr, int32 $length, int32 $prot, int32 $flags, int32 $fd, int32 $offset) returns CArray[uint8] is native {*}

my $dbg = 0;

class Table does Iterable does Iterator {
    has $.num-rows;

    has $!field-offset;
    has $!nullable-fields;
    has $!layer-flags;
    has $!size-offset;
    has $!has-m;
    has $!has-z;
    has $!offset-pointer;
    has $!remaining-rows;
    has @!fields;
    has $!bytes;
    has $!offsets;
    has $!row-num;

    my $epoch = DateTime.new(year => 1899,
                             month => 12,
                             day => 31); # reverse engineered doco says "30"

    method dump {
        say "$!num-rows rows";
        say "field offset: $!field-offset";
        say "$!nullable-fields nullable fields";
        say "size of offsets: $!size-offset";
        say "$!offset-pointer bytes into .tablx file";
        say "$!remaining-rows remaining rows (including deleted rows)";
        say @!fields.raku;
#        say $!bytes;
#        say $!offsets;
    }

    method iterator() { self }
    
    method pull-one ( --> Mu ) {
        if $!remaining-rows {
            my $offset = 0;
            while !$offset && $!remaining-rows {
                $!row-num++;
                my $shift = 0;
                for ^$!size-offset {
                    $offset += ($!offsets[$!offset-pointer++] +& 0xff) +< $shift;
                    $shift += 8;
                }
                $!remaining-rows--;
            }
            my $row = self!read-row($offset);
            $row<.row-num.> = $!row-num;
            $row;
        } else {
            IterationEnd;
        }
    }

    submethod TWEAK(:$dir, :$table) {
        $!nullable-fields = 0;
        my $file-table = $dir ~ sprintf('/a%08x.gdbtable', $table);
        note "Opening $file-table" if $dbg;
        my $fh = $file-table.IO.open or fail "Could not open $file-table\n";
        my $file-table-length = $file-table.IO.s;
        my $file-tablx = $dir ~ sprintf('/a%08x.gdbtablx', $table);
        note "Opening $file-tablx" if $dbg;
        my $fhx = $file-tablx.IO.open or fail "Could not open $file-tablx\n";
        my $file-tablx-length = $file-tablx.IO.s;
        
        $!bytes = mmap(Pointer, $file-table-length, 1, 1, $fh.native-descriptor, 0);
        $!offsets = mmap(Pointer, $file-tablx-length, 1, 1, $fhx.native-descriptor, 0);
        my $magic-number  = read-int32($!bytes,  0);
           $!num-rows     = read-int32($!bytes,  4);
        my $file-size     = read-int32($!bytes, 24);
           $!field-offset = read-int64($!bytes, 32);
        # read field definitions
        my $field-length = read-int32($!bytes, $!field-offset     );
        my $file-version = read-int32($!bytes, $!field-offset +  4);
        fail "Only version 10 file supported" unless $file-version == 4;
        $!layer-flags  = read-int32($!bytes, $!field-offset +  8);
        my $geometry-type = $!layer-flags +& 0xff;
        $!has-z = so $!layer-flags +& 0x80000000;
        $!has-m = so $!layer-flags +& 0x40000000;
        my $num-fields  = read-int16($!bytes, $!field-offset + 12);
        my $pointer = $!field-offset + 14;
        for ^$num-fields {
            my %field;
            %field<name> = get-string($!bytes, $pointer);
            %field<alias> = get-string($!bytes, $pointer);
            my $field-type = $!bytes[$pointer++];
            %field<type> = $field-type;
            given $field-type {
                when 0|1|2|3|5 { # "default" behaviour
                    %field<width>   = $!bytes[$pointer++];
                    %field<flag>    = $!bytes[$pointer++];
                    %field<default> = get-ldfint($!bytes, $pointer);
                }
                when 4 { # string
                    %field<max-length> = read-int32($!bytes, $pointer); $pointer += 4;
                    %field<flag> = $!bytes[$pointer++];
                    %field<default> = get-string($!bytes, $pointer);
                }
                when 6 { # object-id
                    %field<unknown1> = $!bytes[$pointer++];
                    %field<unknown2> = $!bytes[$pointer++];
                }
                when 7 { # geometry
                    $pointer++; # always 0
                    %field<flag> = $!bytes[$pointer++] +& 0xff;
                    my $length = read-int16($!bytes, $pointer); $pointer += 2;
                    my @array = ();
                    for ^$length {
                        @array.push($!bytes[$pointer++] +& 0xff);
                    }
                    %field<srs> = Blob.new(@array).decode('utf16le');
                    %field<flags> = $!bytes[$pointer++] +& 0xff;
                    %field<has-z> = so %field<flags> +& 0x02;
                    %field<has-m> = so %field<flags> +& 0x04;
                    %field<xorigin> = read-float64($!bytes, $pointer); $pointer += 8;
                    %field<yorigin> = read-float64($!bytes, $pointer); $pointer += 8;
                    %field<xyscale> = read-float64($!bytes, $pointer); $pointer += 8;
                    if %field<has-m> {
                        %field<morigin> = read-float64($!bytes, $pointer); $pointer += 8;
                        %field<mscale> = read-float64($!bytes, $pointer); $pointer += 8;
                    }
                    if %field<has-z> {
                        %field<zorigin> = read-float64($!bytes, $pointer); $pointer += 8;
                        %field<zscale> = read-float64($!bytes, $pointer); $pointer += 8;
                    }
                    %field<xytolerance> = read-float64($!bytes, $pointer); $pointer += 8;
                    if %field<has-m> {%field<mtolerance> = read-float64($!bytes, $pointer); $pointer += 8;}
                    if %field<has-z> {%field<ztolerance> = read-float64($!bytes, $pointer); $pointer += 8;}
                    %field<xmin> = read-float64($!bytes, $pointer); $pointer += 8;
                    %field<ymin> = read-float64($!bytes, $pointer); $pointer += 8;
                    %field<xmax> = read-float64($!bytes, $pointer); $pointer += 8;
                    %field<ymax> = read-float64($!bytes, $pointer); $pointer += 8;
                    if $!layer-flags +& 0x80000000 {
                        %field<zmin> = read-float64($!bytes, $pointer); $pointer += 8;
                        %field<zmax> = read-float64($!bytes, $pointer); $pointer += 8;
                    }
                    if $!layer-flags +& 0x40000000 {
                        %field<mmin> = read-float64($!bytes, $pointer); $pointer += 8;
                        %field<mmax> = read-float64($!bytes, $pointer); $pointer += 8;
                    }
                    dd $pointer if $dbg;
                    note $pointer.base(16) if $dbg;
                    $pointer++; # always 0
                    %field<num-spatial-grid-sizes> = read-int32($!bytes, $pointer); $pointer += 4;
                    dd %field if $dbg;
                    for ^%field<num-spatial-grid-sizes> {
                        %field<grid-size>.push(read-float64($!bytes, $pointer));
                        $pointer += 8;
                    }
                    dd %field if $dbg;
                    # incomplete
                }
                default {
                    fail "Unhandled field type $field-type";
                }
            }
            if %field<flag>.defined && %field<flag> +& 0x01 {
                %field<is-nullable> = True;
                $!nullable-fields++;
            } else {
                %field<is-nullable> = False;
            }                                             
            dd %field if $dbg;
            @!fields.push(%field);
        }
        dd @!fields if $dbg;
        # Now the tablx headers...
        my $magic2 = read-int32($!offsets, 0);
        dd $magic2 if $dbg;
        my $n1024blockspresent = read-int32($!offsets, 4);
        dd $n1024blockspresent if $dbg;
        my $number-of-rows = read-int32($!offsets, 8); # includes deleted rows
        dd $number-of-rows if $dbg;
        $!size-offset = read-int32($!offsets, 12); # includes deleted rows
        dd $!size-offset if $dbg;
        my $trailer = 16 + $!size-offset * $n1024blockspresent*1024;
        my $nBitmapInt32Words = read-int32($!offsets, $trailer);
        dd $nBitmapInt32Words if $dbg;
        my $n1024BlocksTotal = read-int32($!offsets, $trailer + 4);
        dd $n1024BlocksTotal if $dbg;
        my $n1024BlocksPresentBis = read-int32($!offsets, $trailer + 8);
        dd $n1024BlocksPresentBis if $dbg;
        my $nUsefulBitmapInt32Words = read-int32($!offsets, $trailer + 12);
        dd $nUsefulBitmapInt32Words if $dbg;
        if $nBitmapInt32Words {
            fail "Tablx bitmap not supported";
        }

        $!offset-pointer = 16; # pointer into the tablx file
        $!remaining-rows = $number-of-rows;
    }

    sub read-int16($carray, $offset) {
        ($carray[$offset  ] +& 0xff)       +|
        ($carray[$offset+1] +& 0xff) +<  8;
    }

    sub read-int32($carray, $offset) {
        ($carray[$offset  ] +& 0xff)      +|
        ($carray[$offset+1] +& 0xff) +<  8 +|
        ($carray[$offset+2] +& 0xff) +< 16 +|
        ($carray[$offset+3] +& 0xff) +< 24;
    }

    sub read-int64($carray, $offset) {
        ($carray[$offset  ] +& 0xff)       +|
        ($carray[$offset+1] +& 0xff) +<  8 +|
        ($carray[$offset+2] +& 0xff) +< 16 +|
        ($carray[$offset+3] +& 0xff) +< 24 +|
        ($carray[$offset+4] +& 0xff) +< 32 +|
        ($carray[$offset+5] +& 0xff) +< 40 +|
        ($carray[$offset+6] +& 0xff) +< 48 +|
        ($carray[$offset+7] +& 0xff) +< 56;
    }

    sub read-varuint($carray, $offset is rw) {
        my $value = 0;
        my $shift = 0;
        loop {
            my $byte = $carray[$offset++];
            $value += ($byte +& 0x7f) +< $shift;
            $shift += 7;
            last unless $byte +& 0x80;
        }
        $value;
    }

    sub read-varint($carray, $offset is rw) {
        my $value = 0;
        my $shift = 6;
        my $byte = $carray[$offset++] +& 0xff;
        my $sign = so $byte +& 0x40;
        $value = $byte +& 0x3f;
        while $byte +& 0x80 {
            $byte = $carray[$offset++] +& 0xff;
            $value += ($byte +& 0x7f) +< $shift;
            $shift += 7;
        }
        $value *= -1 if $sign;
        $value;
    }

    sub read-float64($carray, $offset) {
        nativecast((num64), Blob.new($carray[ $offset .. $offset+7 ] ));
    }

    sub get-string($carray, $pointer is rw)
    {
        my $num-chars = $carray[$pointer++];
        my @chars;
        while $num-chars-- {
            @chars.push($carray[$pointer++]);
            @chars.push($carray[$pointer++]);
        }
        Blob.new(@chars).decode('utf16le');
    }

    sub get-ldfint($carray, $pointer is rw) {
        my $length = $carray[$pointer++] +& 0xff;
        my $value = 0;
        my $shift = 0;
        while $length-- {
            $value += ($carray[$pointer++] +& 0xff) +< $shift;
            $shift += 8;
        }
        $value;
    }

    sub make-string($s is copy) {
        $s ~~ s:g/\\/\\\\/;
        $s ~~ s:g/\'/\\'/;
        $s ~~ s:g/\n/\\n/;
        $s ~~ s:g/\r/\\r/;
        $s ~~ s:g/"\b"/\\b/;
        $s ~~ s:g/\t/\\t/;
        $s;
    }
    
    method !read-point($pointer is rw, $field) {
        my $x = read-varuint($!bytes, $pointer) / $field<xyscale> + $field<xorigin>;
        my $y = read-varuint($!bytes, $pointer) / $field<xyscale> + $field<yorigin>;
        my $z = read-varuint($!bytes, $pointer) / $field<zscale> + $field<zorigin> if $!has-z;
        my $m = read-varuint($!bytes, $pointer) / $field<mscale> + $field<morigin> if $!has-m;
        if $!has-z {
            if $!has-m {
                PointZM.new($x, $y, $z, $m);
            } else {
                PointZ.new($x, $y, $z);
            }
        } else {
            if $!has-m {
                PointM.new($x, $y, $m);
            } else {
                Point.new($x, $y);
            }
        }
    }

    method !read-row($pointer is copy) {
        my %row;
        note "Reading row at offset {$pointer.base(16)}" if $dbg;
        dd $!nullable-fields if $dbg;
        my $field-count = read-int32($!bytes, $pointer); $pointer += 4;
        dd $field-count if $dbg;
        # read null field bits
        my @null = ();
        for ^(($!nullable-fields+7) div 8) {
            @null.push($!bytes[$pointer++] +& 0xff);
        }
        @null.push(0);
        dd @null if $dbg;
        my $null-mask = 0x00;
        my $null-byte;
        for @!fields -> $field {
            dd $field if $dbg;
            note "pointer is {$pointer.base(16)}" if $dbg;
            my $value;
            if $field<is-nullable> {
                $null-mask +<= 1;
                if $null-mask +& 0xff == 0 {
                    $null-mask = 0x01;
                    $null-byte = @null.shift;
                }
                dd $null-mask if $dbg;
                note $null-byte.base(16) if $dbg;
                if $null-byte +& $null-mask != 0 { # field is null
                    note "{$field<name>} IS NULL" if $dbg;
                    %row{$field<name>} = Nil;
                    next;
                } else {
                }
            }
            given $field<type> {
                when 1 {
                    $value = read-int32($!bytes, $pointer); $pointer += 4;
                    note "$value ({$value.base(16)}" if $dbg;
                }
                when 3 {
                    $value = read-float64($!bytes, $pointer); $pointer += 8;
                    dd $value if $dbg;
                }
                when 4|12 {
                    my $length = $!bytes[$pointer++];
                    my @array;
                    for ^$length {
                        @array.push: $!bytes[$pointer++];
                    }
                    $value = Blob.new(@array).decode;
                    dd $value if $dbg;
                }
                when 5 {
                    my $time = read-float64($!bytes, $pointer); $pointer += 8;
                    dd $time if $dbg;
                    $value = ($epoch.later(day => $time));
                    dd $value if $dbg;
                }
                when 6 {
                    $value = Nil;
                    dd $value if $dbg;
                }
                when 7 { # geometry
                    my $length = read-varuint($!bytes, $pointer);
                    dd $length if $dbg;
                    my $geometry-type = read-varuint($!bytes, $pointer);
                    note "geometry type {$geometry-type} ({$geometry-type.base(16)})" if $dbg;
                    given $geometry-type +& 0xff {
                        when 1|9|11|21|52 { # point types
                            $value = self!read-point($pointer, $field);
                        }
                        when 8|18|20|28|53 { # multipoint types
                            my @vals;
                            my $type = 'MULTIPOINT';
                            my $num-points = read-varuint($!bytes, $pointer);
                            my $xmin = read-varuint($!bytes, $pointer) ?? $field<xyscale> + $field<xorigin>;
                            my $ymin = read-varuint($!bytes, $pointer) ?? $field<xyscale> + $field<xorigin>;
                            my $xmax = read-varuint($!bytes, $pointer) ?? $field<xyscale> + $field<xorigin>;
                            my $ymax = read-varuint($!bytes, $pointer) ?? $field<xyscale> + $field<xorigin>;
                            my $x = $field<xorigin>;
                            my $y = $field<yorigin>;
                            for ^$num-points {
                                my $x += read-varuint($!bytes, $pointer) / $field<xyscale>;
                                my $y += read-varuint($!bytes, $pointer) / $field<xyscale>;
                                @vals.push: @($x, $y);
                            }
                            if $!has-z {
                                $type ~= 'Z';
                                my $z = $field<zorigin>;
                                for ^$num-points -> $i {
                                    my $z += read-varuint($!bytes, $pointer) / $field<zscale>;
                                    @vals[$i].push: $z;
                                }
                            }
                            if $!has-m {
                                $type ~= 'M';
                                for ^$num-points -> $i {
                                    my $m = read-varuint($!bytes, $pointer) / $field<mscale> + $field<morogin>;
                                    @vals[$i].push: $m;
                                }
                            }
                            given $type {
                                when 'MULTIPOINT' {
                                    $value = MultiPoint.new(points => @vals.map: {Point.new($_[0], $_[1])});
                                }
                                when 'MULTIPOINTZ' {
                                    $value = MultiPointZ.new(points => @vals.map: {Point.new($_[0], $_[1], $_[2])});
                                }
                                when 'MULTIPOINTM' {
                                    $value = MultiPointM.new(points => @vals.map: {Point.new($_[0], $_[1], $_[2])});
                                }
                                when 'MULTIPOINTZM' {
                                    $value = MultiPointZM.new(points => @vals.map: {Point.new($_[0], $_[1], $_[2], $_[3])});
                                }
                            }
                            dd $value if $dbg;
                        }
                        when 3|10|13|23|50 { # polyline
                            my $type = 'MULTILINESTRING';
                            my @points;
                            my @vals;
                            my $num-points = read-varuint($!bytes, $pointer);
                            my $num-parts  = read-varuint($!bytes, $pointer);
                            $pointer++; # what's this byte?
                            note "line types with $num-points points in $num-parts parts" if $dbg;
                            my $xmin = read-varuint($!bytes, $pointer) ?? $field<xyscale> + $field<xorigin>;
                            my $ymin = read-varuint($!bytes, $pointer) ?? $field<xyscale> + $field<yorigin>;
                            my $xmax = read-varuint($!bytes, $pointer) ?? $field<xyscale> + $field<xorigin>;
                            my $ymax = read-varuint($!bytes, $pointer) ?? $field<xyscale> + $field<yorigin>;
                            note "bbox: $xmin ??? $xmax, $ymin ??? $ymax" if $dbg;
                            my $x = $field<xorigin>;
                            my $y = $field<yorigin>;
                            my @part-length;
                            for ^($num-parts - 1) {
                                @part-length.push: read-varuint($!bytes, $pointer);
                            }
                            @part-length.push: $num-points - [+] @part-length; # length of final part is not explicit
                            for ^$num-points {
                                my $dx = read-varint($!bytes, $pointer);
                                $x += $dx ?? $field<xyscale>;
                                my $dy = read-varint($!bytes, $pointer);
                                $y += $dy ?? $field<xyscale>;
                                my @point = ($x, $y);
                                @points.push: @point;
                            }
                            if $!has-z {
                                $type ~= 'Z';
                                my $z = $field<zorigin>;
                                for ^$num-points -> $i {
                                    my $dz = read-varint($!bytes, $pointer);
                                    $z += $dz ?? $field<zscale>;
                                    @points[$i].push($z);
                                }
                            }
                            if $!has-m {
                                $type ~= 'M';
                                my $m = $field<morigin>;
                                for ^$num-points -> $i {
                                    $m += read-varint($!bytes, $pointer) ?? $field<mscale>;
                                    @points[$i].push($m);
                                }
                            }
                            my $val = @points.map({.join(' ')}).join(',');
                            $value = wkt($type, @points, length => @part-length);
                            dd $value if $dbg;
                        }
                        when 5|15|19|25|51 { # polygon
                            my $type = 'MULTIPOLYGON';
                            my @points;
                            my @vals;
                            my $num-points = read-varuint($!bytes, $pointer);
                            my $num-parts  = read-varuint($!bytes, $pointer);
                            $pointer++; # There's a byte in here I don't understand
                            note "polygon type with $num-points points in $num-parts parts" if $dbg;
                            my $xmin = read-varuint($!bytes, $pointer) ?? $field<xyscale> + $field<xorigin>;
                            my $ymin = read-varuint($!bytes, $pointer) ?? $field<xyscale> + $field<yorigin>;
                            my $xmax = read-varuint($!bytes, $pointer) ?? $field<xyscale> + $field<xorigin>;
                            my $ymax = read-varuint($!bytes, $pointer) ?? $field<xyscale> + $field<yorigin>;
                            note "bbox: $xmin ??? $xmax, $ymin ??? $ymax" if $dbg;
                            my $x = $field<xorigin>;
                            my $y = $field<yorigin>;
                            my @part-length;
                            for ^($num-parts - 1) {
                                @part-length.push: read-varuint($!bytes, $pointer);
                            }
                            @part-length.push: $num-points - [+] @part-length;
                            for ^$num-points {
                                my $dx = read-varint($!bytes, $pointer);
                                $x += $dx ?? $field<xyscale>;
                                my $dy = read-varint($!bytes, $pointer);
                                $y += $dy ?? $field<xyscale>;
                                my @point = ($x, $y);
                                @points.push: @point;
                            }
                            if $!has-z {
                                $type ~= 'Z';
                                my $z = $field<zorigin>;
                                for ^$num-points -> $i {
                                    my $dz = read-varint($!bytes, $pointer);
                                    $z += $dz ?? $field<zscale>;
                                    @points[$i].push($z);
                                }
                            }
                            if $!has-m {
                                $type ~= 'M';
                                my $m = $field<morigin>;
                                for ^$num-points -> $i {
                                    $m += read-varint($!bytes, $pointer) ?? $field<mscale>;
                                    @points[$i].push($m);
                                }
                            }
#dd @points[0], @points[*-1];
                            @points.push(@points[0]) unless @points[0] eqv @points[*-1];
#dd @points[0], @points[*-1];
#dd @points;
                            my $val = @points.map({.join(' ')}).join(',');
                            $value = wkt($type, @points, length => +@points);
                            dd $value if $dbg;
#dd $value;
                        }
                        default {
                            die "Unknown geometry type $geometry-type ({$geometry-type.base(16)})";
                        }
                    }
                }
                default {
                    fail "Unsupported field type {$field<type>}";
                }
            }
            %row{$field<name>} = $value;
        }
        note "Finished reading row -- pointer is {$pointer.base(16)}" if $dbg;
        %row;
    }

    sub wkt($type, $vals, :$length = (Inf)) {
        given $type {
            when 'POINT'|'POINTZ'|'POINTM'|'POINTZM' {
                $type ~ '(' ~ $vals.join(' ') ~ ')';
            }
            when 'MULTIPOINT' {
                $type ~ '(' ~ $vals.map({.join(' ')}).join(',') ~ ')';
            }
            when 'MULTILINESTRING' |
                 'MULTILINESTRINGZ' |
                 'MULTILINESTRINGM' |
                 'MULTILINESTRINGZM' |
                 'MULTIPOLYGON' |
                 'MULTIPOLYGONZ' |
                 'MULTIPOLYGONM' |
                 'MULTIPOLYGONZM'
                 {
                my @vals;
                dd $length if $dbg;
                my $offset = 0;
                for |$length -> $l {
                    dd $l if $dbg;
                    note "Copying values from $offset to {$offset + $l}" if $dbg;
                    if $l >= 0 {
                        @vals.push: $vals[$offset ..^ $offset + $l];
                    } else {
                        @vals.push: $vals[$offset .. *];
                    }
                    $offset += $l;
                }
                my $v = @vals.map({.map({
                                         .join(' ')
                                        }).join(',')
                                  }).join('),(');
                $type ~ '((' ~ $v ~ '))';
            }
            default {
                die "Unknown WKT geometry type '$type'";
            }
        }
    }
        
    sub wkt-to-insert($wkt is copy) {
        $wkt ~~ s/'('/ST_GeomFromText(/;
        $wkt ~~ s/')'$/), 4326)/;
        $wkt;
    }
    
    sub wkt-to-copy($wkt) {
        'SRID=4326;' ~ $wkt;
    }
    
    method make-insert($row, :$table = 'XXX') {
        my @columns;
        my @values;
        for @!fields -> $field {
            my $field-name = $field<name>;
            if $row{$field-name}.val.defined {
                given $row{$field-name} {
                    default { # don't generate entry
                    }
                    when Real { # just straight Numeric?) value
                        @columns.push: $field-name;
                        @values.push:  $row{$field-name}.val // '\N';
                    }
                    when Str { # string value
                        @columns.push: $field-name;
                        @values.push:  "E'" ~ make-string($row{$field-name}.val) ~ "'";
                    }
                    when Geometry { # geometry
                        @columns.push: $field-name;
                        @values.push:  wkt-to-insert($row{$field-name}.val);
                    }
                    
                    @columns.push: $field-name;
                    @values.push:  $row{$field-name}.sql;
                }
            }
        }
        "INSERT INTO $table (" ~ @columns.join(', ') ~ ") VALUES (" ~ @values.join(', ') ~ ");";
    }
    
    method make-copy($row) {
        my @values;
        for @!fields -> $field {
            next if $field<type> == 6; # auto fields
            my $field-name = $field<name>;
            if $row{$field-name}.defined && $row{$field-name}.defined {
                given $row{$field-name} {
                    default { # don't generate entry
                    }
                    when Real { # straight numeric value
                        @values.push:  $row{$field-name} // '\N';
                    }
                    when Str { # straight string value
                        my $val = $row{$field-name};
                        if $val.defined {
                            $val ~~ s:g/\\/\\\\/;
                            $val ~~ s:g/\n/\\n/;
                            $val ~~ s:g/\r/\\r/;
                            $val ~~ s:g/\t/\\t/;
                            $val ~~ s:g/"\b"/\\b/;
                        }
                        @values.push:  $val // '\N';
                    }
                    when Geometry { # geometry
                        @values.push:  wkt-to-copy($row{$field-name});
                    }
#                    default {
#                        X::AdHoc.new("Unknown ValueField type {$row{$field-name}}");
#                    }
                }
            } else {
                @values.push: '\N';
            }
        }
        @values.join("\t");
    }
    
    method make-copy-cmd($file, $table = 'XXX') {
        my @columns;
        for @!fields -> $field {
            @columns.push: $field<name> unless $field<type> == 6;
        }
        "\\COPY $table (" ~ @columns.join(', ') ~ ") from '$file';";
    }
    
    method create-table(:$table = 'XXX') {
        my @geometry-columns;
        my @def;
        my @defstart;
        my @defend;
        for @!fields -> $field {
            given $field<type> {
                when 0|1 {
                    my $def = "{$field<name>} int";
                    $def ~= " NOT NULL" unless $field<is-nullable>;
                    @def.push: $def;
                }
                when 3 {
                    my $def = "{$field<name>} float";
                    $def ~= " NOT NULL" unless $field<is-nullable>;
                    @def.push: $def;
                }
                when 4 {
                    my $def ~= "{$field<name>} text";
                    $def ~= " NOT NULL" unless $field<is-nullable>;
                    @def.push: $def;
                }
                when 5 {
                    my $def ~= "{$field<name>} timestamp";
                    $def ~= " NOT NULL" unless $field<is-nullable>;
                    @def.push: $def;
                }
                when 6 {
                    my $sequence-name = $table ~ '_sequence';
                    @defstart.push: "CREATE SEQUENCE $sequence-name;";
                    my $def = "{$field<name>} bigint DEFAULT nextval('{$sequence-name}') PRIMARY KEY";
                    $def ~= " NOT NULL" unless $field<is-nullable>;
                    @def.push: $def;
                }
                when 7 {
                    @geometry-columns.push($field<name>);
                }
            }
        }
        for @geometry-columns {
            @defend.push: "SELECT AddGeometryColumn('', '{$table.lc}', '{$_.lc}', 4326, 'POINT', 2);";
            @defend.push: "CREATE INDEX {$table}_index ON $table USING gist($_)";
        }
        @defstart.join("\n") ~
        "\nCREATE TABLE $table (\n  " ~
        @def.join(",\n  ") ~
        "\n);\n" ~
        @defend.join("\n") ~
        ";\n";
    }   
}

=begin pod
=TITLE Geo::filegdb
=head1 Geo::filegdb

A class to allow easy reading of fileGDB geographic databases.

=head2 Usage example

=begin code
    my $dir = '/home/user/gdb-directory'; # the directory containing the database
    my $system-table := Geo::filegdb::Table.new($dir, table => 1);
    for $system-table -> $row {
        if $row<.row-num.> > 8 { # skip system tables
            my $table := Geo::filegdb::Table.new(:$dir, $row<.row-num.>);
            for $table -> $row {
                # process row of data
            }
        }
    }
=end code

=head1 Background

FileGDB is a file format defined by ESRI and often used for transfer of geographic data information. Each database is contained in a single directory, with each database table being represented by a set of files. File names are of the form C<aXXXXXXXX.<extension>>, where C<XXXXXXXX> is a lower-case hexadecimal number. This class (at the moment) only uses files with extension C<.table> and C<.tablx> which contain the data itself and information about row positions in the data file. The other files contain information necessary and useful when the database is being actively updated and used, including indexes and information about free space.

Table 1 (in files C<a00000001.table> and C<a00000001.tablx>, and usually called C<GDB_SystemCatalog>) contain the system table catalog with information about the tables in the database. The first eight tables (the number depends on the file format version, but we currently only support file version 4, corresponding to fGDB10) contain other generic information, and not user data. The table number (and thus file names) is not stored directly in the system catalog, but is inferred from the row number in the system catalog. There are often deleted (or skipped) entries in the system catalog. These correspond to tables which are not present. Thus the file names may skip some numbers. In addition, tables defined in the system catalog do not necessarily exist. The existence of the files needs to be checked as well.

ESR?? do not release file format information; this module relies on the reverse-engineered information available at L<https://github.com/rouault/dump_gdbtable/wiki/FGDB-Spec>.

=head1 Creating a Table

C<Table.new> will return a C<Table> object which is an iterator. The C<new> method requires two named arguments. the C<dir> argument is the pathname of the directory containing the database, and the C<table> argument is the number of the table to be opened. The system table is number 1.

Note that it is essential that the new Table be bound to a variable and not assigned to it.
The C<Table> object is an iterator. If you assign it to a variable, the first row will be assigned to the variable rather than the iterator.

C<Table.new> will return a Failure if it cannot open the table for whatever reason.

=head1 Using the Table
                                                                    
The only publicly accessible attribute of a table is the number of rows, available using the C<num-rows> method.

It is generally possible to use a C<Table> without actually directly calling any methods other than C<new>. In its simplest form, the code under "Usage example" above is all that is needed to read a table row by row.

Each row is returned as a hash of column name to values. In addition the pseudo-row C<.row-num.> contains the row number in the table. For example, the system catalog table (the first table) will return rows which look like:

=begin code
  ${".row-num." => 1, :FileFormat(0), :ID(Any), :Name("GDB_SystemCatalog")}
=end code

Some auxiliary methods are available for handling some aspects of tables. For example, the following code will generate a PostgreSQL copy file and print the commands to create the tables and copy them from the file into a database. The PosgreSQL database will need to jave PostGIS installed.

=begin code
  my $system-table := Table.new(dir => $database-directory, table => 1);
  if $system-table {
    for $system-table => $row {
      if $row<.row-num.> > 8 {
        my $table = $row<Name>;
        my $data-table := Table.new(dir => $database-directory, table => $row<.row-num.>);
        if $data-table {
          my $file-name = $table ~ '.copy';
          my $copy-file = $filename.IO.open;
          for $data-table -> $data-row {
            $copy-file.print($data-table.make-copy($row));
          }
          $copy-file.close;
          put $data-table.create-table;
          put $data-table.make-copy-cmd($filename, $table);
        }
      }
    }
  }
=end code

=head1 Auxiliary methods
=head2 dump

The C<dump> method will "say" some information about the table which is otherwise not directly accessible. It can be convenient for debugging. C<dump> takes no arguments.

=head2 iterator

The C<iterator> method is part of the C<Iterator> interface. You shouldn't need to use it explicitly. )It just returns C<self> anyway.) C<iterator> takes no arguments.

=head2 pull-one

The C<pull-one> method returns the next row from the table. It is the interface used during iteration, and so is usually not explicitly called. C<pull-one> takes no arguments.
                                                                                                        
=head2 make-insert

The <make-insert> method takes one positional  argument. This is a row of the table as returned by the iterator.  There is also a named argument C<table> which is the name of a table. The default for the table name is "XXX".

The method returns a string containing a SQL insert statement which will insert the data into the table named by the C>table> argument.

=head2 make-copy

The C<make-copy> method takes a positional argument which is a row of the table as returned by the iterator. It's output is a string containing the row in PostgreSQL copy format.

=head2 make-copy-cmd

The C<make-copy-cmd> method takes two arguments. The name of a file, and an optional table name. The table name defaults to 'XXX'.

The output is a string containing a PostgreSQL C<copy> command which will load the table from the given file.

=head2 create-table

The C<create-table> method takes a single optional named argument C<table> (default "XXX"). It returns a string containing SQL commands to create a table of the given name.
                                                                    
=end pod
