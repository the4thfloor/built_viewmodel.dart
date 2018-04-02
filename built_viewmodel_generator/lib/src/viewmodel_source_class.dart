// Copyright (c) 2018., Ralph Bergmann.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:code_builder/code_builder.dart';
import 'package:dart_style/dart_style.dart';

class ViewModelSourceClass {
  final ClassElement element;
  final List<_HandlerRef> _handlerRefs = [];

  ViewModelSourceClass(ClassElement this.element);

  static bool isSourceFile(ClassElement classElement) {
    return !classElement.displayName.startsWith('_\$') &&
        (classElement.allSupertypes.any((InterfaceType interfaceType) => interfaceType.displayName == 'ViewModel'));
  }

  String get _name => element.displayName;

  String get _implName => _name.startsWith('_') ? '_\$${_name.substring(1)}' : '_\$$_name';

  String generateCode() {
    for (final MethodElement method in element.methods) {
      method.metadata
          .where((ElementAnnotation annotation) => _isSupportedAnnotation(annotation.computeConstantValue()))
          .forEach((ElementAnnotation annotation) => _handlerRefs.add(new _HandlerRef(
              method.name,
              annotation.computeConstantValue().getField('callback').toStringValue(),
              annotation.computeConstantValue().getField('name').toStringValue())));
    }

    final result = new StringBuffer();
    result.write(_generateImpl());
    result.write(_generateController());
    result.write(_generateControllerImpl());

    return result.toString();
  }

  String _generateImpl() {
    final impl = new Class((b) {
      b
        ..name = _implName
        ..extend = refer(_name)
        ..constructors.add(new Constructor((b) => b
          ..factory = true
          ..lambda = true
          ..body = new Code('new $_implName._()')))
        ..constructors.add(new Constructor((b) => b
          ..name = '_'
          ..initializers.add(new Code('super._()'))));

      element.fields.where((FieldElement field) => _isSupportedType(field.type)).forEach((FieldElement field) {
        final Field newField = new Field((b) => b
          ..name = '_${field.name}'
          ..type = refer('Stream<${_getGenericType(field)}>'));
        final Method newMethod = new Method((b) => b
          ..name = '${field.name}'
          ..type = MethodType.getter
          ..lambda = true
          ..annotations.add(new CodeExpression(new Code('override')))
          ..returns = refer(field.type.toString())
          ..body = new Code('_${field.name} ??= controller.${field.name}.stream.asBroadcastStream()'));

        b..fields.add(newField)..methods.add(newMethod);
      });

      final newControllerField = new Field((b) => b
        ..name = '_controller'
        ..type = refer('${_name}Controller'));
      final newGetControllerMethod = new Method((b) => b
        ..name = 'controller'
        ..type = MethodType.getter
        ..lambda = true
        ..returns = newControllerField.type
        ..body = new Code('${newControllerField.name} ??= new _\$${_name}Controller()${_handlerRefs
            .map((_HandlerRef ref) => '.._${_lowerCamelCase([ref.stream, ref.handler])} = ${ref.method}')
            .join()}'));
      b..fields.add(newControllerField)..methods.add(newGetControllerMethod);

      b
        ..methods.add(new Method.returnsVoid((b) => b
          ..name = 'dispose'
          ..annotations.add(new CodeExpression(new Code('override')))
          ..body = new Code('controller.dispose();')));

      return b;
    });
    return new DartFormatter().format('${impl.accept(new DartEmitter())}');
  }

  String _generateController() {
    final controller = new Class((b) => b
      ..name = '${_name}Controller'
      ..implements.add(refer('Controller'))
      ..abstract = true
      ..methods.addAll(
        element.fields.where((FieldElement field) => _isSupportedType(field.type)).map(
              (FieldElement field) => new Method((b) => b
                ..name = field.name
                ..type = MethodType.getter
                ..returns = refer('StreamController<${_getGenericType(field)}>')),
            ),
      ));
    return new DartFormatter().format('${controller.accept(new DartEmitter())}');
  }

  String _generateControllerImpl() {
    final controller = new Class((b) {
      b
        ..name = '_\$${_name}Controller'
        ..extend = refer('${_name}Controller')
        ..fields.addAll(_handlerRefs.map((_HandlerRef ref) => new Field((b) => b
          ..name = '_${_lowerCamelCase([ref.stream, ref.handler])}'
          ..type = refer('Function '))));

      element.fields.where((FieldElement field) => _isSupportedType(field.type)).forEach((FieldElement field) {
        final Field newField = new Field((b) => b
          ..name = '_${field.name}'
          ..type = refer('StreamController<${_getGenericType(field)}>'));
        final Method newMethod = new Method((b) => b
          ..name = '${field.name}'
          ..type = MethodType.getter
          ..lambda = true
          ..returns = newField.type
          ..body = new Code('${newField.name} ??= new StreamController<${_getGenericType(field)}>(${ _handlerRefs
              .where((_HandlerRef ref) => ref.stream == field.name)
              .map((_HandlerRef ref) => '${ref.handler}: _${_lowerCamelCase([ref.stream, ref.handler])}')
              .join(', ')})'));

        b..fields.add(newField)..methods.add(newMethod);
      });

      b
        ..methods.add(new Method.returnsVoid((b) => b
          ..name = 'dispose'
          ..annotations.add(new CodeExpression(new Code('override')))
          ..body = new Code(element.fields
              .where((field) => _isSupportedType(field.type))
              .map((field) => '_${field.name}.close();')
              .join())));

      return b;
    });
    return new DartFormatter().format('${controller.accept(new DartEmitter())}');
  }

  bool _isSupportedType(DartType type) => type.name == 'Stream';

  bool _isSupportedAnnotation(DartObject value) =>
      value?.type?.displayName == 'OnListenHandler' ||
      value?.type?.displayName == 'OnPauseHandler' ||
      value?.type?.displayName == 'OnResumeHandler' ||
      value?.type?.displayName == 'OnCancelHandler';

  String _getGenericType(FieldElement e) {
    final typeArguments = (e.type as InterfaceType).typeArguments;
    return typeArguments.map((DartType type) => type.name).join(', ');
  }

  String _lowerCamelCase(List<String> parts) {
    if (parts == null || parts.isEmpty) return null;
    if (parts.length == 1) return parts.first;
    return '${parts.first}${parts.skip(1).map((String part) => _firstToUpperCase(part)).join()}';
  }

  String _firstToUpperCase(String string) => string.replaceRange(0, 1, string.substring(0, 1).toUpperCase());
}

class _HandlerRef {
  final String method;
  final String handler;
  final String stream;

  const _HandlerRef(this.method, this.handler, this.stream);
}
