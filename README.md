TITLE
=====

Geo::filegdb

Geo::filegdb
============

A class to allow easy reading of fileGDB geographic databases.

Usage example
-------------

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

Background
==========

FileGDB is a file format defined by ESRI and often used for transfer of geographic data information. Each database is contained in a single directory, with each database table being represented by a set of files. File names are of the form `aXXXXXXXX.<extension>`, where `XXXXXXXX` is a lower-case hexadecimal number. This class (at the moment) only uses files with extension `.table` and `.tablx` which contain the data itself and information about row positions in the data file. The other files contain information necessary and useful when the database is being actively updated and used, including indexes and information about free space.

Table 1 (in files `a00000001.table` and `a00000001.tablx`, and usually called `GDB_SystemCatalog`) contain the system table catalog with information about the tables in the database. The first eight tables (the number depends on the file format version, but we currently only support file version 4, corresponding to fGDB10) contain other generic information, and not user data. The table number (and thus file names) is not stored directly in the system catalog, but is inferred from the row number in the system catalog. There are often deleted (or skipped) entries in the system catalog. These correspond to tables which are not present. Thus the file names may skip some numbers. In addition, tables defined in the system catalog do not necessarily exist. The existence of the files needs to be checked as well.

ESRΙ do not release file format information; this module relies on the reverse-engineered information available at [https://github.com/rouault/dump_gdbtable/wiki/FGDB-Spec](https://github.com/rouault/dump_gdbtable/wiki/FGDB-Spec).

Creating a Table
================

`Table.new` will return a `Table` object which is an iterator. The `new` method requires two named arguments. the `dir` argument is the pathname of the directory containing the database, and the `table` argument is the number of the table to be opened. The system table is number 1.

Note that it is essential that the new Table be bound to a variable and not assigned to it. The `Table` object is an iterator. If you assign it to a variable, the first row will be assigned to the variable rather than the iterator.

`Table.new` will return a Failure if it cannot open the table for whatever reason.

Using the Table
===============

The only publicly accessible attribute of a table is the number of rows, available using the `num-rows` method.

It is generally possible to use a `Table` without actually directly calling any methods other than `new`. In its simplest form, the code under "Usage example" above is all that is needed to read a table row by row.

Each row is returned as a hash of column name to values. In addition the pseudo-row `.row-num.` contains the row number in the table. For example, the system catalog table (the first table) will return rows which look like:

      ${".row-num." => 1, :FileFormat(0), :ID(Any), :Name("GDB_SystemCatalog")}

Some auxiliary methods are available for handling some aspects of tables. For example, the following code will generate a PostgreSQL copy file and print the commands to create the tables and copy them from the file into a database. The PosgreSQL database will need to jave PostGIS installed.

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

Auxiliary methods
=================

dump
----

The `dump` method will "say" some information about the table which is otherwise not directly accessible. It can be convenient for debugging. `dump` takes no arguments.

iterator
--------

The `iterator` method is part of the `Iterator` interface. You shouldn't need to use it explicitly. )It just returns `self` anyway.) `iterator` takes no arguments.

pull-one
--------

The `pull-one` method returns the next row from the table. It is the interface used during iteration, and so is usually not explicitly called. `pull-one` takes no arguments.

make-insert
-----------

The <make-insert> method takes one positional argument. This is a row of the table as returned by the iterator. There is also a named argument `table` which is the name of a table. The default for the table name is "XXX".

The method returns a string containing a SQL insert statement which will insert the data into the table named by the C>table> argument.

make-copy
---------

The `make-copy` method takes a positional argument which is a row of the table as returned by the iterator. It's output is a string containing the row in PostgreSQL copy format.

make-copy-cmd
-------------

The `make-copy-cmd` method takes two arguments. The name of a file, and an optional table name. The table name defaults to 'XXX'.

The output is a string containing a PostgreSQL `copy` command which will load the table from the given file.

create-table
------------

The `create-table` method takes a single optional named argument `table` (default "XXX"). It returns a string containing SQL commands to create a table of the given name.

