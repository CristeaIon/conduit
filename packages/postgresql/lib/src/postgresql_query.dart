import 'dart:async';

import 'package:conduit_core/conduit_core.dart';
import 'postgresql_query_reduce.dart';
import 'query_builder.dart';

class PostgresQuery<InstanceType extends ManagedObject> extends Object
    with QueryMixin<InstanceType>
    implements Query<InstanceType> {
  PostgresQuery(this.context);

  PostgresQuery.withEntity(this.context, this._entity);

  @override
  ManagedContext context;

  @override
  ManagedEntity get entity => _entity;

  late ManagedEntity _entity = context.dataModel!.entityForType(InstanceType);

  @override
  QueryReduceOperation<InstanceType> get reduce {
    return PostgresQueryReduce(this);
  }

  @override
  Future<InstanceType> insert() async {
    validateInput(Validating.insert);

    final builder = PostgresQueryBuilder(this);

    final buffer = StringBuffer();
    buffer.write("INSERT INTO ${builder.sqlTableName} ");

    if (builder.columnValueBuilders.isNotEmpty) {
      buffer.write("(${builder.sqlColumnsToInsert}) ");
    }

    buffer.write("VALUES (${builder.sqlValuesToInsert}) ");

    if (builder.returning.isNotEmpty) {
      buffer.write("RETURNING ${builder.sqlColumnsToReturn}");
    }

    final results = await context.persistentStore
        .executeQuery(buffer.toString(), builder.variables, timeoutInSeconds);

    return builder
        .instancesForRows<InstanceType>(results as List<List<dynamic>>)
        .first;
  }

  @override
  Future<List<InstanceType>> insertMany(List<InstanceType?> objects) async {
    if (objects.isEmpty) {
      return [];
    }

    final buffer = StringBuffer();

    final allColumns = <String>{};
    final builders = <PostgresQueryBuilder>[];

    for (int i = 0; i < objects.length; i++) {
      values = objects[i];
      validateInput(Validating.insert);

      builders.add(PostgresQueryBuilder(this, "$i"));
      allColumns.addAll(builders.last.columnValueKeys);
    }

    buffer.write("INSERT INTO ${builders.first.sqlTableName} ");

    if (allColumns.isEmpty) {
      buffer.write("VALUES ");
    } else {
      buffer.write("(${allColumns.join(',')}) VALUES ");
    }

    final valuesToInsert = <String>[];
    final allVariables = <String, dynamic>{};

    for (final builder in builders) {
      valuesToInsert.add("(${builder.valuesToInsert(allColumns)})");
      allVariables.addAll(builder.variables);
    }

    buffer.writeAll(valuesToInsert, ",");
    buffer.write(" ");

    if (builders.first.returning.isNotEmpty) {
      buffer.write("RETURNING ${builders.first.sqlColumnsToReturn}");
    }

    final results = await context.persistentStore
        .executeQuery(buffer.toString(), allVariables, timeoutInSeconds);

    return builders.first
        .instancesForRows<InstanceType>(results as List<List<dynamic>>);
  }

  @override
  Future<List<InstanceType>> update() async {
    validateInput(Validating.update);

    final builder = PostgresQueryBuilder(this);

    final buffer = StringBuffer();
    buffer.write("UPDATE ${builder.sqlTableName} ");
    buffer.write("SET ${builder.sqlColumnsAndValuesToUpdate} ");

    if (builder.sqlWhereClause != null) {
      buffer.write("WHERE ${builder.sqlWhereClause} ");
    } else if (!canModifyAllInstances) {
      throw canModifyAllInstancesError;
    }

    if (builder.returning.isNotEmpty) {
      buffer.write("RETURNING ${builder.sqlColumnsToReturn}");
    }

    final results = await context.persistentStore
        .executeQuery(buffer.toString(), builder.variables, timeoutInSeconds);

    return builder.instancesForRows(results as List<List<dynamic>>);
  }

  @override
  Future<InstanceType?> updateOne() async {
    final results = await update();
    if (results.length == 1) {
      return results.first;
    } else if (results.isEmpty) {
      return null;
    }

    throw StateError(
        "Query error. 'updateOne' modified more than one row in '${entity.tableName}'. "
        "This was likely unintended and may be indicativate of a more serious error. Query "
        "should add 'where' constraints on a unique column.");
  }

  @override
  Future<int> delete() async {
    final builder = PostgresQueryBuilder(this);

    final buffer = StringBuffer();
    buffer.write("DELETE FROM ${builder.sqlTableName} ");

    if (builder.sqlWhereClause != null) {
      buffer.write("WHERE ${builder.sqlWhereClause} ");
    } else if (!canModifyAllInstances) {
      throw canModifyAllInstancesError;
    }

    final int result = await context.persistentStore.executeQuery(
      buffer.toString(),
      builder.variables,
      timeoutInSeconds,
      returnType: PersistentStoreQueryReturnType.rowCount,
    );
    return result;
  }

  @override
  Future<InstanceType?> fetchOne() async {
    final builder = createFetchBuilder();

    if (!builder.containsJoins) {
      fetchLimit = 1;
    }
    final results = await _fetch(builder);
    if (results.length == 1) {
      return results.first;
    } else if (results.length > 1) {
      throw StateError(
          "Query error. 'fetchOne' returned more than one row from '${entity.tableName}'. "
          "This was likely unintended and may be indicativate of a more serious error. Query "
          "should add 'where' constraints on a unique column.");
    }

    return null;
  }

  @override
  Future<List<InstanceType>> fetch() async {
    return _fetch(createFetchBuilder());
  }

  //////

  PostgresQueryBuilder createFetchBuilder() {
    final builder = PostgresQueryBuilder(this);

    if (pageDescriptor != null) {
      validatePageDescriptor();
      if (builder.containsJoins) {
        throw StateError(
          "Invalid query. Cannot set both 'pageDescription' and use 'join' in query.",
        );
      }
    }

    return builder;
  }

  Future<List<InstanceType>> _fetch(PostgresQueryBuilder builder) async {
    final buffer = StringBuffer();
    buffer.write("SELECT ${builder.sqlColumnsToReturn} ");
    buffer.write("FROM ${builder.sqlTableName} ");

    if (builder.containsJoins) {
      buffer.write("${builder.sqlJoin} ");
    }

    if (builder.sqlWhereClause != null) {
      buffer.write("WHERE ${builder.sqlWhereClause} ");
    }

    buffer.write("${builder.sqlOrderBy} ");

    if (fetchLimit != 0) {
      buffer.write("LIMIT $fetchLimit ");
    }

    if (offset != 0) {
      buffer.write("OFFSET $offset ");
    }
    final results = await context.persistentStore
        .executeQuery(buffer.toString(), builder.variables, timeoutInSeconds);
    return builder.instancesForRows(results as List<List<dynamic>>);
  }

  void validatePageDescriptor() {
    final pd = pageDescriptor!;
    final prop = entity.attributes[pd.propertyName];
    if (prop == null) {
      throw StateError(
        "Invalid query page descriptor. Column '${pd.propertyName}' does not exist for table '${entity.tableName}'",
      );
    }

    if (pd.boundingValue != null && !prop.isAssignableWith(pd.boundingValue)) {
      throw StateError(
        "Invalid query page descriptor. Bounding value for column '${pd.propertyName}' has invalid type.",
      );
    }
  }

  static final StateError canModifyAllInstancesError = StateError(
    "Invalid Query<T>. Query is either update or delete query with no WHERE clause. To confirm this query is correct, set 'canModifyAllInstances' to true.",
  );
}
