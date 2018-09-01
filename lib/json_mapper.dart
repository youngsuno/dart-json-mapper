library json_mapper;

import 'dart:convert';

import 'package:dart_json_mapper/annotations.dart';
import 'package:dart_json_mapper/converters.dart';
import 'package:dart_json_mapper/errors.dart';
import "package:reflectable/reflectable.dart";

/// Singleton class providing static methods for Dart objects conversion
/// from / to JSON string
class JsonMapper {
  static final JsonMapper instance = JsonMapper._internal();
  final JsonEncoder jsonEncoder = JsonEncoder.withIndent(" ");
  final JsonDecoder jsonDecoder = JsonDecoder();
  final serializable = const JsonSerializable();
  final Map<String, ClassMirror> classes = {};
  final Map<String, Object> processedObjects = {};
  final Map<Type, ICustomConverter> converters = {};

  /// Assign custom converter instance for certain Type handling
  static void registerConverter(Type type, ICustomConverter converter) {
    instance.converters[type] = converter;
  }

  /// Converts Dart object to JSON string, indented by `indent`
  static String serialize(Object object, [String indent]) {
    instance.processedObjects.clear();
    JsonEncoder encoder = instance.jsonEncoder;
    if (indent != null && indent.isEmpty) {
      encoder = JsonEncoder();
    } else {
      if (indent != null && indent.isNotEmpty) {
        encoder = JsonEncoder.withIndent(indent);
      }
    }
    return encoder.convert(instance.serializeObject(object));
  }

  /// Converts JSON string to Dart object of type T
  static T deserialize<T>(String jsonValue) {
    assert(T != dynamic ? true : throw MissingTypeForDeserializationError());
    return instance.deserializeObject(jsonValue, T);
  }

  factory JsonMapper() => instance;

  JsonMapper._internal() {
    for (ClassMirror classMirror in serializable.annotatedClasses) {
      classes[classMirror.simpleName] = classMirror;
    }
    registerDefaultConverters();
  }

  void registerDefaultConverters() {
    converters[dynamic] = defaultConverter;
    converters[String] = defaultConverter;
    converters[bool] = defaultConverter;
    converters[Symbol] = symbolConverter;
    converters[DateTime] = dateConverter;
    converters[num] = numberConverter;
    converters[int] = numberConverter;
    converters[double] = numberConverter;
  }

  MethodMirror getPublicConstructor(ClassMirror classMirror) {
    return classMirror.declarations.values.where((DeclarationMirror dm) {
      return !dm.isPrivate && dm is MethodMirror && dm.isConstructor;
    }).first;
  }

  List<String> getPublicFieldNames(ClassMirror classMirror) {
    Map<String, MethodMirror> instanceMembers = classMirror.instanceMembers;
    return instanceMembers.values
        .where((MethodMirror method) {
          return method.isGetter && method.isSynthetic && !method.isPrivate;
        })
        .map((MethodMirror method) => method.simpleName)
        .toList();
  }

  InstanceMirror safeGetInstanceMirror(Object object) {
    InstanceMirror result;
    try {
      result = serializable.reflect(object);
    } catch (error) {}
    return result;
  }

  String getObjectKey(Object object) {
    return '${object.runtimeType}-${object.hashCode}';
  }

  bool isObjectAlreadyProcessed(Object object) {
    bool result = false;

    if (object.runtimeType.toString() == 'Null' ||
        object.runtimeType.toString() == 'bool') {
      return result;
    }

    String key = getObjectKey(object);
    if (processedObjects.containsKey(key)) {
      result = true;
    } else {
      processedObjects[key] = object;
    }
    return result;
  }

  Type getScalarType(Type type) {
    String itemTypeName = type.toString();
    if (itemTypeName.indexOf("List<") == 0) {
      itemTypeName =
          itemTypeName.substring("List<".length, itemTypeName.length - 1);
      if (itemTypeName == "DateTime") {
        return DateTime;
      }
      if (itemTypeName == "num") {
        return num;
      }
      if (itemTypeName == "bool") {
        return bool;
      }
      if (itemTypeName == "String") {
        return String;
      }
    }

    if (classes[itemTypeName] != null) {
      return classes[itemTypeName].reflectedType;
    }

    return type;
  }

  ICustomConverter getConverter(JsonProperty jsonProperty, Type type) {
    ICustomConverter result =
        jsonProperty != null ? jsonProperty.converter : null;
    if (jsonProperty != null &&
        jsonProperty.enumValues != null &&
        result == null) {
      result = enumConverter;
    }
    if (result == null && converters[type] != null) {
      result = converters[type];
    }
    if (result == null && type.toString().indexOf('Map<') == 0) {
      result = defaultConverter;
    }
    return result;
  }

  enumeratePublicFields(InstanceMirror instanceMirror, Function visitor) {
    ClassMirror classMirror = instanceMirror.type;
    for (String name in getPublicFieldNames(classMirror)) {
      String jsonName = name;
      VariableMirror variableMirror =
          classMirror.declarations[name] as VariableMirror;
      Type variableScalarType = getScalarType(variableMirror.reflectedType);
      bool isGetterOnly = classMirror.instanceMembers[name + '='] == null;
      JsonProperty meta = classMirror.declarations[name].metadata
          .firstWhere((m) => m is JsonProperty, orElse: () => null);
      if (meta != null && meta.ignore == true) {
        continue;
      }
      if (meta != null && meta.name != null) {
        jsonName = meta.name;
      }
      visitor(name, jsonName, instanceMirror.invokeGetter(name), isGetterOnly,
          meta, getConverter(meta, variableScalarType), variableScalarType);
    }
  }

  enumerateConstructorParameters(ClassMirror classMirror, Function visitor) {
    MethodMirror methodMirror = getPublicConstructor(classMirror);
    if (methodMirror == null) {
      return;
    }
    methodMirror.parameters.forEach((ParameterMirror param) {
      String name = param.simpleName;
      VariableMirror variableMirror =
          classMirror.declarations[name] as VariableMirror;
      String jsonName = name;
      JsonProperty meta = variableMirror.metadata
          .firstWhere((m) => m is JsonProperty, orElse: () => null);
      if (meta != null && meta.name != null) {
        jsonName = meta.name;
      }

      visitor(param, name, jsonName, meta, variableMirror.reflectedType);
    });
  }

  Map<Symbol, dynamic> getNamedArguments(
      ClassMirror cm, Map<String, dynamic> jsonMap) {
    Map<Symbol, dynamic> result = Map();

    enumerateConstructorParameters(cm, (param, name, jsonName, meta, type) {
      if (meta != null && meta.ignore == true) {
        return;
      }
      if (param.isNamed && jsonMap.containsKey(name)) {
        result[Symbol(name)] = deserializeObject(jsonMap[name], type, meta);
      }
    });

    return result;
  }

  List getPositionalArguments(ClassMirror cm, Map<String, dynamic> jsonMap) {
    List result = [];

    enumerateConstructorParameters(cm,
        (param, name, jsonName, JsonProperty meta, type) {
      if (!param.isOptional &&
          !param.isNamed &&
          jsonMap.containsKey(jsonName)) {
        var value = deserializeObject(jsonMap[jsonName], type, meta);
        if (meta != null && meta.ignore == true) {
          value = null;
        }
        result.add(value);
      }
    });

    return result;
  }

  dynamic serializeObject(Object object) {
    if (object == null) {
      return object;
    }

    if (isObjectAlreadyProcessed(object)) {
      throw CircularReferenceError(object);
    }

    ICustomConverter converter = getConverter(null, object.runtimeType);
    if (converter != null) {
      return converter.toJSON(object, null);
    }

    if (object is List) {
      return object.map(serializeObject).toList();
    }
    InstanceMirror im = safeGetInstanceMirror(object);

    if (im == null || im.type == null) {
      if (im != null) {
        throw MissingEnumValuesError(object.runtimeType);
      } else {
        throw MissingAnnotationOnTypeError(object.runtimeType);
      }
    }

    Map result = {};
    enumeratePublicFields(im,
        (name, jsonName, value, isGetterOnly, meta, converter, type) {
      if (converter != null) {
        convert(item) => converter.toJSON(item, meta);
        if (value is List) {
          result[jsonName] = value.map(convert).toList();
        } else {
          result[jsonName] = convert(value);
        }
      } else {
        result[jsonName] = serializeObject(value);
      }
    });
    return result;
  }

  Object deserializeObject(dynamic jsonValue, Type instanceType,
      [JsonProperty parentMeta]) {
    ICustomConverter converter = getConverter(parentMeta, instanceType);
    if (converter != null) {
      return converter.fromJSON(jsonValue, parentMeta);
    }

    ClassMirror cm = classes[instanceType.toString()];
    if (cm == null) {
      throw MissingAnnotationOnTypeError(instanceType);
    }
    Map<String, dynamic> jsonMap =
        (jsonValue is String) ? jsonDecoder.convert(jsonValue) : jsonValue;
    Object objectInstance = cm.isEnum
        ? null
        : cm.newInstance("", getPositionalArguments(cm, jsonMap),
            getNamedArguments(cm, jsonMap));
    InstanceMirror im = safeGetInstanceMirror(objectInstance);

    enumeratePublicFields(im,
        (name, jsonName, value, isGetterOnly, meta, converter, type) {
      var fieldValue = jsonMap[jsonName];
      if (type != null) {
        if (fieldValue is List) {
          fieldValue = fieldValue
              .map((item) => deserializeObject(item, type, meta))
              .toList();
        } else {
          fieldValue = deserializeObject(fieldValue, type, meta);
        }
      }
      if (converter != null) {
        convert(item) => converter.fromJSON(item, meta);
        if (fieldValue is List) {
          fieldValue = fieldValue.map(convert).toList();
        } else {
          fieldValue = convert(fieldValue);
        }
      }
      if (!isGetterOnly) {
        var l = im.invokeGetter(name);
        if (l is List && fieldValue is List) {
          fieldValue.map((item) => l.add(item));
        } else {
          im.invokeSetter(name, fieldValue);
        }
      }
    });
    return objectInstance;
  }
}
