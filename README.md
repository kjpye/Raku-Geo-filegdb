# Geo::filegdb

----
----
## Table of Contents
[Geo::filegdb](#geofilegdb)  
[Usage example](#usage-example)  
[Background](#background)  
[Creating a Table](#creating-a-table)  
[Using the Table](#using-the-table)  
[Auxiliary methods](#auxiliary-methods)  
[dump](#dump)  
[iterator](#iterator)  
[pull-one](#pull-one)  
[read-point](#read-point)  
[read-row](#read-row)  
[make-insert](#make-insert)  
[make-copy](#make-copy)  
[make-copy-cmd](#make-copy-cmd)  
[create-table](#create-table)  

----
# Geo::filegdb
A class to allow easy reading of fileGDB geographic databases.

## Usage example
```
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

```
# Background
FileGDB is a file format defined by ESRI and often used for transfer of geographic data information. Each database is contained in a single directory, with each database table being represented by a set of files. File names are of the form `aXXXXXXXX.<extension>`, where `XXXXXXXX` is a lower-case hexadecimal number. This class (at the moment) only uses files with extension `.table` and `.tablx` which contain the data itself and information about row positions in the data file. The other files contain information necessary and useful when the database is being actively updated and used, including indexes and information about free space.

Table 1 (in files `a00000001.table` and `a00000001.tablx`, and usually called `GDB_SystemCatalog`) contain the system table catalog with information about the tables in the database. The first eight tables (the number depends on the file format version, but we currently only support file version 4, correspoinding to fGDB10) contain other generic information, and not user data. The table number (and thus file names) is not stored directly in the system catalog, but is inferred from the row number in the system catalog. There are often deleted (or skipped) entries in the system catalog. These correspond to tables which are not present. Thus the file names may skip some numbers.

ESRΙ do not release file format information; this module relies on the reverse-engineered information available at [https://github.com/rouault/dump_gdbtable/wiki/FGDB-Spec](https://github.com/rouault/dump_gdbtable/wiki/FGDB-Spec).

# Creating a Table
`Table.new` will return a `Table` object which is an iterator. The `new` method requires two named arguments. the `dir` argument is the pathname of the directory containing the database, and the `table` argument is the number of the table to be opened. The system table is number 1.

Note that it is essential that the new Table be bound to a variable and not assigned to it. The `Table` object is an iterator. If you assign it to a variable, the first row will be assigned to the variable rather than the iterator.

`Table.new` will return a Failure if it cannot open the table for whatever reason.

# Using the Table
The only publicly accessible attribute of a table is the number of rows, available using the `num-rows` method.

It is generally possible to use a `Table` without actually directly calling any methods other than `new`. In its simplest form, the following code repesents normal usage of this module:

```

```
# Auxiliary methods
## dump
## iterator
## pull-one
## read-point
## read-row
## make-insert
## make-copy
## make-copy-cmd
## create-table






----
Rendered from UNNAMED at 2022-01-22T04:22:11Z
