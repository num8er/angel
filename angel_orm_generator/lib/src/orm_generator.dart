import 'dart:async';
import 'package:analyzer/dart/element/element.dart';
import 'package:angel_orm/angel_orm.dart';
import 'package:angel_serialize_generator/angel_serialize_generator.dart';
import 'package:build/build.dart';
import 'package:code_builder/code_builder.dart' hide LibraryBuilder;
import 'package:source_gen/source_gen.dart';

import 'orm_build_context.dart';

Builder ormBuilder(BuilderOptions options) {
  return new SharedPartBuilder([
    new OrmGenerator(
        autoSnakeCaseNames: options.config['auto_snake_case_names'] != false,
        autoIdAndDateFields: options.config['auto_id_and_date_fields'] != false)
  ], 'angel_orm');
}

TypeReference futureOf(String type) {
  return new TypeReference((b) => b
    ..symbol = 'Future'
    ..types.add(refer(type)));
}

/// Builder that generates `.orm.g.dart`, with an abstract `FooOrm` class.
class OrmGenerator extends GeneratorForAnnotation<Orm> {
  final bool autoSnakeCaseNames;
  final bool autoIdAndDateFields;

  OrmGenerator({this.autoSnakeCaseNames, this.autoIdAndDateFields});

  @override
  Future<String> generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) async {
    if (element is ClassElement) {
      var ctx = await buildOrmContext(element, annotation, buildStep,
          buildStep.resolver, autoSnakeCaseNames, autoIdAndDateFields);
      var lib = buildOrmLibrary(buildStep.inputId, ctx);
      return lib.accept(new DartEmitter()).toString();
    } else {
      throw 'The @Orm() annotation can only be applied to classes.';
    }
  }

  Library buildOrmLibrary(AssetId inputId, OrmBuildContext ctx) {
    return new Library((lib) {
      // Create `FooQuery` class
      // Create `FooQueryWhere` class
      lib.body.add(buildQueryClass(ctx));
      lib.body.add(buildWhereClass(ctx));
    });
  }

  Class buildQueryClass(OrmBuildContext ctx) {
    // TODO: Handle relations

    return new Class((clazz) {
      var rc = ctx.buildContext.modelClassNameRecase;
      var queryWhereType = refer('${rc.pascalCase}QueryWhere');
      clazz
        ..name = '${rc.pascalCase}Query'
        ..extend = new TypeReference((b) {
          b
            ..symbol = 'Query'
            ..types.addAll([
              ctx.buildContext.modelClassType,
              queryWhereType,
            ]);
        });

      // Add tableName
      clazz.methods.add(new Method((m) {
        m
          ..name = 'tableName'
          ..annotations.add(refer('override'))
          ..type = MethodType.getter
          ..body = new Block((b) {
            b.addExpression(literalString(ctx.tableName).returned);
          });
      }));

      // Add fields getter
      clazz.methods.add(new Method((m) {
        m
          ..name = 'fields'
          ..annotations.add(refer('override'))
          ..type = MethodType.getter
          ..body = new Block((b) {
            var names = ctx.buildContext.fields
                .map((f) => literalString(f.name))
                .toList();
            b.addExpression(literalConstList(names).returned);
          });
      }));

      // Add where member
      clazz.fields.add(new Field((b) {
        b
          ..annotations.add(refer('override'))
          ..name = 'where'
          ..modifier = FieldModifier.final$
          ..type = queryWhereType
          ..assignment = queryWhereType.newInstance([]).code;
      }));

      // Add deserialize()
      clazz.methods.add(new Method((m) {
        m
          ..name = 'deserialize'
          ..annotations.add(refer('override'))
          ..requiredParameters.add(new Parameter((b) => b
            ..name = 'row'
            ..type = refer('List')))
          ..body = new Block((b) {
            int i = 0;
            var args = <String, Expression>{};

            for (var field in ctx.buildContext.fields) {
              var type = convertTypeReference(field.type);
              args[field.name] = (refer('row').index(literalNum(i))).asA(type);
            }

            b.addExpression(
                ctx.buildContext.modelClassType.newInstance([], args).returned);
          });
      }));
    });
  }

  Class buildWhereClass(OrmBuildContext ctx) {
    return new Class((clazz) {
      var rc = ctx.buildContext.modelClassNameRecase;
      clazz
        ..name = '${rc.pascalCase}QueryWhere'
        ..extend = refer('QueryWhere');

      // Build expressionBuilders getter
      clazz.methods.add(new Method((m) {
        m
          ..name = 'expressionBuilders'
          ..annotations.add(refer('override'))
          ..type = MethodType.getter
          ..body = new Block((b) {
            var references = ctx.buildContext.fields.map((f) => refer(f.name));
            b.addExpression(literalList(references).returned);
          });
      }));

      // Add builders for each field
      for (var field in ctx.buildContext.fields) {
        // TODO: Handle fields with relations
        Reference builderType;

        if (const TypeChecker.fromRuntime(String).isExactlyType(field.type)) {
          builderType = refer('StringSqlExpressionBuilder');
        } else if (const TypeChecker.fromRuntime(bool)
            .isExactlyType(field.type)) {
          builderType = refer('BooleanSqlExpressionBuilder');
        } else if (const TypeChecker.fromRuntime(DateTime)
            .isExactlyType(field.type)) {
          builderType = refer('DateTimeSqlExpressionBuilder');
        } else if (const TypeChecker.fromRuntime(int)
                .isExactlyType(field.type) ||
            const TypeChecker.fromRuntime(double).isExactlyType(field.type)) {
          builderType = new TypeReference((b) => b
            ..symbol = 'NumericSqlExpressionBuilder'
            ..types.add(refer(field.type.name)));
        } else {
          throw new UnsupportedError(
              'Cannot generate ORM code for field of type ${field.type.name}.');
        }

        clazz.fields.add(new Field((b) {
          b
            ..name = field.name
            ..modifier = FieldModifier.final$
            ..type = builderType
            ..assignment = builderType.newInstance([
              literalString(ctx.buildContext.resolveFieldName(field.name))
            ]).code;
        }));
      }
    });
  }
}
