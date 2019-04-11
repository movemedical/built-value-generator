import 'dart:async';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:dart_style/dart_style.dart';
import 'package:source_gen/source_gen.dart';

class MoveSerializerBuilder extends Builder {
  @override
  Future build(BuildStep buildStep) async {
    var inputId = buildStep.inputId;
    final resolver = buildStep.resolver;
    if (!await resolver.isLibrary(inputId)) return null;

    final lib = await buildStep.inputLibrary;

    final serializersForAnnotations = Map<String, ElementAnnotation>();

    final accessors = lib.definingCompilationUnit.accessors
        .where((element) =>
            element.isGetter &&
            (element.returnType.displayName == 'Serializers' ||
                element.returnType.displayName == 'SerializersBuilder'))
        .toList();

    for (final accessor in accessors) {
      final annotations = accessor.variable.metadata
          .where((annotation) =>
              annotation.computeConstantValue()?.type?.displayName ==
              'SerializersFor')
          .toList();
      if (annotations.isEmpty) continue;

      serializersForAnnotations[accessor.name] = annotations.single;
    }

    if (serializersForAnnotations.isEmpty) return null;

    final imports = Imports();
    for (final field in serializersForAnnotations.keys) {
      final serializersForAnnotation = serializersForAnnotations[field];

      final types = serializersForAnnotation
          .computeConstantValue()
          .getField('types')
          .toListValue()
          ?.map((dartObject) => dartObject.toTypeValue());

      if (types == null) {
        // This only happens if the source code is invalid.
        throw InvalidGenerationSourceError(
            'Broken @SerializersFor annotation. Are all the types imported?');
      }

      types.forEach((type) => SourceClass.create(type, imports));
    }

    /// Generates serializer source for this library.
    String generateCode() {
      final buffer = StringBuffer();

      buffer.writeln('import \'package:built_value/serializer.dart\';');
      buffer.writeln(
          'import \'package:built_collection/built_collection.dart\';');
      buffer.writeln('import \'package:modux/modux.dart\';');

      imports.map.values.forEach((import) {
        buffer.writeln(import.importFile);
      });

      serializersForAnnotations.keys.forEach((annotationField) {
        buffer.writeln();
        buffer.writeln(
            'SerializersBuilder \$$annotationField() => (Serializers().toBuilder()');

        void addImport(SourceImport import) {
          import.serializers.forEach((serializer) {
            buffer.writeln('..add($serializer)');
          });
          import.map.values.forEach((builderTypes) {
            builderTypes.values
                .where((builderType) => builderType.needsBuilder)
                .forEach((builderType) {
              buffer.writeln(
                  '..addBuilderFactory(${builderType.fullType}, () => ${builderType.builderName}())');
            });
          });
        }

        addImport(imports.built_collection);

        imports.map.values.forEach(addImport);

        buffer.writeln(');');
      });

      buffer.writeln();
      buffer.writeln('\n// ignore_for_file: '
          'implementation_imports,'
          'always_put_control_body_on_new_line,'
          'always_specify_types,'
          'annotate_overrides,'
          'avoid_annotating_with_dynamic,'
          'avoid_as,'
          'avoid_catches_without_on_clauses,'
          'avoid_returning_this,'
          'lines_longer_than_80_chars,'
          'omit_local_variable_types,'
          'prefer_expression_function_bodies,'
          'sort_constructors_first,'
          'test_types_in_equals,'
          'unnecessary_const,'
          'unnecessary_new');

      return buffer.toString();
    }

//
    final outputId = inputId.changeExtension('.gg.dart');

//    // Write out the new asset.
    await buildStep.writeAsString(outputId, _formatter.format(generateCode()));
    return null;
  }

  @override
  final buildExtensions = const {
    '.ser.dart': ['.ser.gg.dart']
  };
}

class SourceImport implements Comparable<SourceImport> {
  final String name;
  final String libraryName;
  final String importFile;

  final Set<String> serializers = Set();
  final Map<String, Map<String, SourceClass>> map = {};

  SourceImport(this.name, this.libraryName, this.importFile);

  String withPrefix(String name) {
    if (libraryName != null && libraryName.isNotEmpty)
      return '$libraryName.$name';
    return name;
  }

  void register(SourceClass cls) {
    if (cls == null) return;

    if (cls.serializable) {
      if (libraryName != null && libraryName.isNotEmpty) {
        serializers.add('$libraryName.${cls.type.name}.serializer');
      } else {
        serializers.add('${cls.type.name}.serializer');
      }
    }

    var m = map[cls.type.name];
    if (m == null) {
      m = <String, SourceClass>{};
      map[cls.type.name] = m;
    }

    m[cls.displayName] = cls;
  }

  @override
  int compareTo(SourceImport other) =>
      (importFile ?? '').compareTo(other?.importFile ?? '');
}

final _formatter = DartFormatter();

String _cleanFullName(String fullName) {
  if (fullName.startsWith('/')) fullName = fullName.substring(1);
  return fullName.replaceFirst('/lib/', '/').replaceFirst('|lib/', '/');
}

class Imports {
  final core = SourceImport('', '', '');
  final unknown = SourceImport('', '', '');
  final modux = SourceImport('', '', '');
  final built_value = SourceImport('', '', '');
  final built_collection = SourceImport('', '', '');
  final map = <String, SourceImport>{};
  var count = 0;

  SourceImport getForType(DartType type) => get(type?.element);

  SourceImport get(Element element) {
    if (element == null) return unknown;
    final source = element.source;
    if (source == null) return unknown;

    String cleanedFullName = _cleanFullName(source.fullName);

    if (cleanedFullName.startsWith('modux')) {
      return modux;
    }

    if (cleanedFullName.startsWith('built_value')) {
      return built_value;
    }
    if (cleanedFullName.startsWith('built_collection')) {
      return built_collection;
    }
    var import = map[source.fullName];
    if (import == null) {
      final libraryName = '_${count++}';

      import = SourceImport(source.fullName, libraryName,
          'import \'package:$cleanedFullName\' as $libraryName;');
//          'import \'package:${_cleanFullName(source.fullName)}\' as $libraryName;');
      map[source.fullName] = import;
    }
    return import;
  }

  void dump() {
    final buffer = StringBuffer();
    map.values.forEach((import) {
      buffer.writeln('Import: ${import.name}');
      import.map.forEach((k, v) {
        buffer.writeln('\tKey: $k');
        v.forEach((k2, v2) {
          buffer.writeln('\t\t$k2 -> ${v2.displayName}');
          buffer.writeln('\t\t\t$k2 -> ${v2.builderName}');
        });
      });
    });

    print(buffer.toString());
  }
}

class SourceClass {
  final DartType type;
  final ClassElement element;
  final SourceImport import;
  final bool serializable;
  final List<SourceClass> typeArguments;
  final List<SourceClass> props;
  final String displayName;
  final String builderName;
  final String fullType;

  String get name => type?.name ?? '';

  bool get needsBuilder => typeArguments.isNotEmpty;

  SourceClass(
      this.type,
      this.element,
      this.import,
      this.serializable,
      this.typeArguments,
      this.props,
      this.displayName,
      this.builderName,
      this.fullType);

  static SourceClass create(DartType type, Imports imports) {
    if (type == null) return null;

    final el = type.element;
    if (el == null) return null;

    final lib = el.library;
    if (lib == null) return null;

    if (lib.isDartCore) {
      switch (type.name) {
        case 'bool':
          return SourceClass(
              type, type.element, imports.core, true, [], [], 'bool', '', '');
        case 'int':
          return SourceClass(
              type, type.element, imports.core, true, [], [], 'int', '', '');
        case 'num':
          return SourceClass(
              type, type.element, imports.core, true, [], [], 'num', '', '');

        case 'double':
          return SourceClass(
              type, type.element, imports.core, true, [], [], 'double', '', '');

        case 'String':
          return SourceClass(
              type, type.element, imports.core, true, [], [], 'String', '', '');

        case 'DateTime':
          return SourceClass(type, type.element, imports.core, true, [], [],
              'DateTime', '', '');

        case 'Duration':
          return SourceClass(type, type.element, imports.core, true, [], [],
              'Duration', '', '');

        case 'Uri':
          return SourceClass(
              type, type.element, imports.core, true, [], [], 'Uri', '', '');

        default:
          return null;
      }
    }

    if (type is InterfaceType) {
      final element = type.element;
      if (element == null) return null;

      final source = element.source;
      if (source == null) return null;

      final name = type.name;
      final overrideBuilderName = typesWithBuilder[name];

      final import = imports.get(element);
      if (import == null) return null;

      final args = type.typeArguments
          .map((t) => create(t, imports))
          .where((s) => s != null)
          .toList();

      final displayName = StringBuffer(import.withPrefix(name));
      final builderName = StringBuffer(import.withPrefix(
          overrideBuilderName != null
              ? '$overrideBuilderName'
              : '${name}Builder'));
      final fullType = StringBuffer('FullType(${import.withPrefix(name)}');
      if (args.isNotEmpty) {
        fullType.write(', [');
        displayName.write('<');
        builderName.write('<');

        bool first = true;
        for (final arg in args) {
          if (first) {
            first = false;
          } else {
            displayName.write(', ');
            builderName.write(', ');
            fullType.write(', ');
          }
          displayName.write(arg.displayName);
          builderName.write(arg.displayName);
          fullType.write(arg.fullType);
        }
        displayName.write('>');
        builderName.write('>');
        fullType.write('])');
      } else {
        fullType.write(')');
      }

      final serializable = type.accessors.firstWhere(
              (p) => p.isStatic && p.name == 'serializer',
              orElse: () => null) !=
          null;

      final props = typesWithBuilder[name] != null
          ? <SourceClass>[]
          : type.accessors
              .where((f) =>
                  !f.isStatic &&
                  f.returnType != null &&
                  f.returnType.element != null)
              .map((prop) => create(prop.returnType, imports))
              .where((s) => s != null)
              .toList();

      final cls = SourceClass(type, element, import, serializable, args, props,
          displayName.toString(), builderName.toString(), fullType.toString());

      import.register(cls);

      return cls;
    } else {}

    return null;
  }

  static bool isTemplate(DartType t) {
    if (t is InterfaceType) {
      if (t.typeParameters.length > t.typeArguments.length) return true;
      for (final arg in t.typeArguments) {
        if (arg.isDynamic ||
            isTemplate(arg) ||
            arg.element.kind == ElementKind.TYPE_PARAMETER) return true;
      }
    }
    return false;
  }
}

final typesWithBuilder = <String, String>{
  'BuiltList': 'ListBuilder',
  'BuiltListMultimap': 'ListMultimapBuilder',
  'BuiltMap': 'MapBuilder',
  'BuiltSet': 'SetBuilder',
  'BuiltSetMultimap': 'SetMultimapBuilder',
};
