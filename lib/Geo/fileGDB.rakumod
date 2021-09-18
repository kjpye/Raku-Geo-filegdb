use NativeCall;
sub mmap(Pointer $addr, int32 $length, int32 $prot, int32 $flags, int32 $fd, int32 $offset) returns CArray[uint8] is native {*}

my $dbg = 0;

class FieldValue {
    has $.val;
    has $.type = 1; # 0 -> none; 1 -> value; 2 -> string; 3 -> geometry
}

class Table does Iterable does Iterator {
    has $!num-rows;
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
                my $shift = 0;
                for ^$!size-offset {
                    $offset += ($!offsets[$!offset-pointer++] +& 0xff) +< $shift;
                    $shift += 8;
                }
                $!remaining-rows--;
            }
            self.read-row($offset);
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
    
    method read-row($pointer is copy) {
        my %row;
        note "Reading row at offset {$pointer.base(16)}" if $dbg;
        dd $!nullable-fields if $dbg;
        my $field-count = read-int32($!bytes, $pointer); $pointer += 4;
        dd $field-count if $dbg;
        # read null field bits
        my @null = ();
        for ^(($!nullable-fields)/8) {
            @null.push($!bytes[$pointer++] +^ 0xff);
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
                if $null-byte +& $null-mask == 0 { # field is null
                    note "{$field<name>} IS NULL" if $dbg;
                    %row{$field<name>} = Nil;
                    next;
                } else {
                }
            }
            given $field<type> {
                when 1 {
                    my $val = read-int32($!bytes, $pointer); $pointer += 4;
                    note "$val ({$val.base(16)}" if $dbg;
                    $value = FieldValue.new(:$val, type => 1);
                }
                when 3 {
                    my $val = read-float64($!bytes, $pointer); $pointer += 8;
                    $value = FieldValue.new(:$val, type => 1);
                    dd $value if $dbg;
                }
                when 4|12 {
                    my $length = $!bytes[$pointer++];
                    my @array;
                    for ^$length {
                        @array.push: $!bytes[$pointer++];
                    }
                    my $val = Blob.new(@array).decode;
                    $value = FieldValue.new(:$val,
                                            type => 2,
                                           );
                    dd $value if $dbg;
                }
                when 5 {
                    my $time = read-float64($!bytes, $pointer); $pointer += 8;
                    dd $time if $dbg;
                    my $val = ($epoch.later(day => $time));
                    $value = FieldValue.new(:$val, type => 2);
                    dd $value if $dbg;
                }
                when 6 {
                    $value = FieldValue.new(val => Nil, type => 0);
                    dd $value if $dbg;
                }
                when 7 {
                    my $length = read-varuint($!bytes, $pointer);
                    dd $length if $dbg;
                    my $geometry-type = read-varuint($!bytes, $pointer);
                    dd $geometry-type if $dbg;
                    given $geometry-type +& 0xff {
                        when 1|9|11|21|52 { # point types
                            my @vals;
                            my $type = 'POINT';
                            my $x = read-varuint($!bytes, $pointer);
                            @vals.push: $x/$field<xyscale> + $field<xorigin>;
                            my $y = read-varuint($!bytes, $pointer);
                            @vals.push: $y/$field<xyscale> + $field<yorigin>;
                            dd $y if $dbg;
                            if $!has-z {
                                $type ~= 'Z';
                                my $z = read-varuint($!bytes, $pointer);
                                @vals.push: ($z-1) ÷ $field<zscale> + $field<zorigin>;
                            }
                            if $!has-m {
                                $type ~= 'M';
                                my $m = read-varuint($!bytes, $pointer);
                                @vals.push: ($m-1) ÷ $field<mscale> + $field<morigin>;
                            }
                            my $val = @vals.join(' ');
                            $value = FieldValue.new(val => wkt($type, @vals), type => 3);
                        }
                        when 8|18|20|28|50 { # polyline
                            my @points;
                            my @vals;
                            my $num-points = read-varuint($!bytes, $pointer);
                            my $xmin = read-varuint($!bytes, $pointer) ÷ $field<xyscale> + $field<xorigin>;
                            my $ymin = read-varuint($!bytes, $pointer) ÷ $field<xyscale> + $field<yorigin>;
                            my $xmax = read-varuint($!bytes, $pointer) ÷ $field<xyscale> + $field<xorigin>;
                            my $ymax = read-varuint($!bytes, $pointer) ÷ $field<xyscale> + $field<yorigin>;
                            note "bbox: $xmin → $xmax, $ymin → $ymax" if $dbg;
                            my $x = $field<xorigin>;
                            my $y = $field<yorigin>;
                            for ^$num-points {
                                my $dx = read-varint($!bytes, $pointer);
                                $x += $dx ÷ $field<xyscale>;
                                my $dy = read-varint($!bytes, $pointer);
                                $y += $dy ÷ $field<xyscale>;
                                my @point = ($x, $y);
                                @points.push(@point);
                            }
                            if $!has-z {
                                my $z = $field<zorogin>;
                                for ^$num-points -> $i {
                                    my $dz = read-varint($!bytes, $pointer);
                                    $z += $dz ÷ $field<zscale>;
                                    @points[$i].push($z);
                                }
                            }
                            my $val = @points.map({.join(' ')}).join(',');
                            $value = FieldValue.new(val => wkt('MULTILINESTRING', @points, type => 3), type => 3);
                        }
                        when 5|51 { # polygon
                            my @points;
                            my @vals;
                            my $num-points = read-varuint($!bytes, $pointer);
                            my $xmin = read-varuint($!bytes, $pointer) ÷ $field<xyscale> + $field<xorigin>;
                            my $ymin = read-varuint($!bytes, $pointer) ÷ $field<xyscale> + $field<yorigin>;
                            my $xmax = read-varuint($!bytes, $pointer) ÷ $field<xyscale> + $field<xorigin>;
                            my $ymax = read-varuint($!bytes, $pointer) ÷ $field<xyscale> + $field<yorigin>;
                            note "bbox: $xmin → $xmax, $ymin → $ymax" if $dbg;
                            my $x = $field<xorigin>;
                            my $y = $field<yorigin>;
                            for ^$num-points {
                                my $dx = read-varint($!bytes, $pointer);
                                $x += $dx ÷ $field<xyscale>;
                                my $dy = read-varint($!bytes, $pointer);
                                $y += $dy ÷ $field<xyscale>;
                                my @point = ($x, $y);
                                @points.push(@point);
                            }
                            if $!has-z {
                                my $z = $field<zorogin>;
                                for ^$num-points -> $i {
                                    my $dz = read-varint($!bytes, $pointer);
                                    $z += $dz ÷ $field<zscale>;
                                    @points[$i].push($z);
                                }
                            }
                            @points.push(@points[0]) unless @points[*-1] === @points[0];
                            my $val = @points.map({.join(' ')}).join(',');
                            $value = FieldValue.new(val => wkt('MULTIPOLYGON', @points), type => 3);
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
        %row;
    }

    sub wkt($type, $vals) {
        given $type {
            when 'POINT'|'POINTZ'|'POINTM'|'POINTZM' {
                $type ~ '(' ~ $vals.join(' ') ~ ')';
            }
            when 'MULTILINESTRING' {
                $type ~ '((' ~ $vals.map({.join(' ')}).join(',') ~ '))';
            }
            when 'MULTIPOLYGON' {
                $vals.push($vals[0]) unless $vals[*-1] === $vals[0];
                '((' ~ $vals.map({.join(' ')}).join(',') ~ '))';
            }
            default {
                X::ADHOC.new("Unknown WKT geometry type")
            }
        }
    }
        
    sub wkt-to-insert($wkt is copy) {
        $wkt ~~ s/'('/ST_GeomFromText(/;
        $wkt ~~ s/')'$/), 4362)/;
        $wkt;
    }
    
    sub wkt-to-copy($wkt) {
        'SRID=4362;' ~ $wkt;
    }
    
    method make-insert($row, :$name = 'XXX') {
        my @columns;
        my @values;
        for @!fields -> $field {
            my $field-name = $field<name>;
            if $row{$field-name}.val.defined {
                given $row{$field-name}.type {
                    when 0 { # don't generate entry
                    }
                    when 1 { # just straight Numeric?) value
                        @columns.push: $field-name;
                        @values.push:  $row{$field-name}.val // '\N';
                    }
                    when 2 { # string value
                        @columns.push: $field-name;
                        @values.push:  "E'" ~ make-string($row{$field-name}.val) ~ "'";
                    }
                    when 3 { # geometry
                        @columns.push: $field-name;
                        @values.push:  wkt-to-insert($row{$field-name}.val);
                    }
                    
                    @columns.push: $field-name;
                    @values.push:  $row{$field-name}.sql;
                }
            }
        }
        "INSERT INTO $name (" ~ @columns.join(', ') ~ ") VALUES (" ~ @values.join(', ') ~ ");";
    }
    
    method make-copy($row, :$name = 'XXX') {
        my @values;
        for @!fields -> $field {
            next if $field<type> == 6; # auto fields
            my $field-name = $field<name>;
            if $row{$field-name}.defined && $row{$field-name}.val.defined {
                given $row{$field-name}.type {
                    when 0 { # don't generate entry
                    }
                    when 1|2 { # just straight numeric or string value
                        @values.push:  $row{$field-name}.val // '\N';
                    }
                    when 3 { # geometry
                        @values.push:  wkt-to-copy($row{$field-name}.val);
                    }
                }
            }
        }
        @values.join("\t");
    }
    
    method make-copy-cmd($file, :$table = 'XXX') {
        my @columns;
        for @!fields -> $field {
            @columns.push: $field<name> unless $field<type> == 6;
        }
        "COPY $table (" ~ @columns.join(', ') ~ ") from '$file';";
    }
    
    method create-table(:$name = 'XXX') {
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
                    my $sequence-name = $name ~ '_sequence';
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
            @defend.push: "SELECT AddGeometryColumn('', '{$name.lc}', '{$_.lc}', 4326, 'POINT', 2);";
            @defend.push: "CREATE INDEX {$name}_index ON $name USING gist($_)";
        }
        @defstart.join("\n") ~
        "\nCREATE TABLE $name (\n  " ~
        @def.join(",\n  ") ~
        "\n);\n" ~
        @defend.join("\n") ~
        ";\n";
    }   
}
