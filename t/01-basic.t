use Test;
use lib 'lib';

# use Geo::Geometry;
use Geo::fileGDB;

my @names = <
	empty
	GDB_SystemCatalog
	GDB_DBTune
	GDB_SpatialRefs
	GDB_Items
	GDB_ItemTypes
	GDB_ItemRelationships
	GDB_ItemRelationshipTypes
	GDB_ReplicaLog
	RECWEB_HUT
	FMA500
>;

my $system-table := Table.new(dir => 't', table => 1);
for $system-table -> $row {
  is $row<Name>, @names[$row<.row-num.>], 'system table';
}

done-testing;
