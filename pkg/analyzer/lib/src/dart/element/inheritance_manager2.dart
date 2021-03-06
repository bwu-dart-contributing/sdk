// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/generated/type_system.dart';
import 'package:analyzer/src/generated/utilities_general.dart';

/// Description of a failure to find a valid override from superinterfaces.
class Conflict {
  /// The name of an instance member for which we failed to find a valid
  /// override.
  final Name name;

  /// The list of candidates for a valid override for a member [name].  It has
  /// at least two items, because otherwise the only candidate is always valid.
  final List<FunctionType> candidates;

  /// The getter that conflicts with the [method], or `null`, if the conflict
  /// is inconsistent inheritance.
  final FunctionType getter;

  /// The method tha conflicts with the [getter], or `null`, if the conflict
  /// is inconsistent inheritance.
  final FunctionType method;

  Conflict(this.name, this.candidates, [this.getter, this.method]);
}

/// Manages knowledge about interface types and their members.
class InheritanceManager2 {
  final StrongTypeSystemImpl _typeSystem;

  /// Cached instance interfaces for [InterfaceType].
  final Map<InterfaceType, Interface> _interfaces = {};

  /// Cached implemented members for [InterfaceType].
  final Map<InterfaceType, Map<Name, FunctionType>> _implemented = {};

  /// Cached member implemented in the mixin.
  final Map<InterfaceType, Map<Name, FunctionType>> _mixinMembers = {};

  InheritanceManager2(this._typeSystem);

  /// Return the interface of the given [type].  It might include private
  /// members, not necessary accessible in all libraries.
  Interface getInterface(InterfaceType type) {
    if (type == null) {
      return const Interface._(const {}, const [{}], const []);
    }

    var result = _interfaces[type];
    if (result != null) {
      return result;
    }

    _interfaces[type] = const Interface._(const {}, const [{}], const []);
    Map<Name, FunctionType> map = {};
    List<Map<Name, FunctionType>> supers = [];
    List<Conflict> conflicts = null;

    // If a class declaration has a member declaration, the signature of that
    // member declaration becomes the signature in the interface.
    _addTypeMembers(map, type);

    Map<Name, List<FunctionType>> namedCandidates = {};
    if (type.element.isMixin) {
      for (var constraint in type.superclassConstraints) {
        _addCandidates(namedCandidates, constraint);
      }

      // `mixin M on S1, S2 {}` can call using `super` any instance member
      // from its superclass constraints, whether it is abstract or concrete.
      Map<Name, FunctionType> mixinSuperClass = {};
      _findMostSpecificFromNamedCandidates(mixinSuperClass, namedCandidates);
      supers.add(mixinSuperClass);
    } else {
      Map<Name, FunctionType> implemented;

      if (type.superclass != null) {
        _addCandidates(namedCandidates, type.superclass);

        implemented = _getImplemented(type.superclass);
        supers.add(implemented);
      }

      for (var mixin in type.mixins) {
        _addCandidates(namedCandidates, mixin);

        var implementedInMixin = _getImplemented(mixin);
        implemented = <Name, FunctionType>{}
          ..addAll(implemented)
          ..addAll(implementedInMixin);
        supers.add(implemented);
      }
    }

    for (var interface in type.interfaces) {
      _addCandidates(namedCandidates, interface);
    }

    // If a class declaration does not have a member declaration with a
    // particular name, but some super-interfaces do have a member with that
    // name, it's a compile-time error if there is no signature among the
    // super-interfaces that is a valid override of all the other
    // super-interface signatures with the same name. That "most specific"
    // signature becomes the signature of the class's interface.
    conflicts = _findMostSpecificFromNamedCandidates(map, namedCandidates);

    var interface = new Interface._(map, supers, conflicts ?? const []);
    _interfaces[type] = interface;
    return interface;
  }

  /// Return the member with the given [name].
  ///
  /// If [concrete] is `true`, the the concrete implementation is returned,
  /// from the given [type], or its superclass.
  ///
  /// If [forSuper] is `true`, then [concrete] is implied, and only concrete
  /// members from the superclass are considered.
  ///
  /// If [forMixinIndex] is specified, only the nominal superclass, and the
  /// given number of mixins after it are considered.  For example for `1` in
  /// `class C extends S with M1, M2, M3`, only `S` and `M1` are considered.
  FunctionType getMember(
    InterfaceType type,
    Name name, {
    bool concrete: false,
    int forMixinIndex: -1,
    bool forSuper: false,
  }) {
    if (forSuper) {
      var supers = getInterface(type)._supers;
      if (forMixinIndex >= 0) {
        return supers[forMixinIndex][name];
      }
      return supers.last[name];
    }
    if (concrete) {
      return _getImplemented(type)[name];
    }
    return getInterface(type).map[name];
  }

  void _addCandidate(Map<Name, List<FunctionType>> namedCandidates, Name name,
      FunctionType candidate) {
    var candidates = namedCandidates[name];
    if (candidates == null) {
      candidates = <FunctionType>[];
      namedCandidates[name] = candidates;
    }

    candidates.add(candidate);
  }

  void _addCandidates(
      Map<Name, List<FunctionType>> namedCandidates, InterfaceType type) {
    getInterface(type).map.forEach((name, candidate) {
      _addCandidate(namedCandidates, name, candidate);
    });
  }

  void _addTypeMembers(Map<Name, FunctionType> map, InterfaceType type) {
    var libraryUri = type.element.librarySource.uri;

    void addTypeMember(ExecutableElement member) {
      if (!member.isStatic) {
        var name = new Name(libraryUri, member.name);
        map[name] = member.type;
      }
    }

    type.methods.forEach(addTypeMember);
    type.accessors.forEach(addTypeMember);
  }

  /// Check that all [candidates] for the given [name] have the same kind, all
  /// getters, all methods, or all setter.  If a conflict found, return the
  /// new [Conflict] instance that describes it.
  Conflict _checkForGetterMethodConflict(
      Name name, List<FunctionType> candidates) {
    assert(candidates.length > 1);

    bool allGetters = true;
    bool allMethods = true;
    bool allSetters = true;
    for (var candidate in candidates) {
      var kind = candidate.element.kind;
      if (kind != ElementKind.GETTER) {
        allGetters = false;
      }
      if (kind != ElementKind.METHOD) {
        allMethods = false;
      }
      if (kind != ElementKind.SETTER) {
        allSetters = false;
      }
    }

    if (allGetters || allMethods || allSetters) {
      return null;
    }

    FunctionType getterType;
    FunctionType methodType;
    for (var candidate in candidates) {
      var kind = candidate.element.kind;
      if (kind == ElementKind.GETTER) {
        getterType ??= candidate;
      }
      if (kind == ElementKind.METHOD) {
        methodType ??= candidate;
      }
    }
    return new Conflict(name, candidates, getterType, methodType);
  }

  /// The given [namedCandidates] maps names to candidates from direct
  /// superinterfaces.  Find the most specific signature, and put it into the
  /// [map], if there is no one yet (from the class itself).  If there is no
  /// such single most specific signature (i.e. no valid override), then add a
  /// new conflict description.
  List<Conflict> _findMostSpecificFromNamedCandidates(
      Map<Name, FunctionType> map,
      Map<Name, List<FunctionType>> namedCandidates) {
    List<Conflict> conflicts = null;

    for (var name in namedCandidates.keys) {
      if (map.containsKey(name)) {
        continue;
      }

      var candidates = namedCandidates[name];

      // If just one candidate, it is always valid.
      if (candidates.length == 1) {
        map[name] = candidates[0];
        continue;
      }

      // Check for a getter/method conflict.
      var conflict = _checkForGetterMethodConflict(name, candidates);
      if (conflict != null) {
        conflicts ??= <Conflict>[];
        conflicts.add(conflict);
      }

      FunctionType validOverride;
      for (var i = 0; i < candidates.length; i++) {
        validOverride = candidates[i];
        for (var j = 0; j < candidates.length; j++) {
          var candidate = candidates[j];
          if (!_typeSystem.isOverrideSubtypeOf(validOverride, candidate)) {
            validOverride = null;
            break;
          }
        }
        if (validOverride != null) {
          break;
        }
      }

      if (validOverride != null) {
        map[name] = validOverride;
      } else {
        conflicts ??= <Conflict>[];
        conflicts.add(new Conflict(name, candidates));
      }
    }

    return conflicts;
  }

  Map<Name, FunctionType> _getImplemented(InterfaceType type) {
    var implemented = _implemented[type];
    if (implemented != null) {
      return implemented;
    }

    _implemented[type] = const {};
    implemented = <Name, FunctionType>{};

    var libraryUri = type.element.librarySource.uri;

    void addMember(ExecutableElement member) {
      if (!member.isAbstract && !member.isStatic) {
        var name = new Name(libraryUri, member.name);
        implemented[name] = member.type;
      }
    }

    void addMembers(InterfaceType type) {
      type.methods.forEach(addMember);
      type.accessors.forEach(addMember);
    }

    if (type.superclass != null) {
      var superImplemented = _getImplemented(type.superclass);
      implemented.addAll(superImplemented);
    }

    // Mixins override the nominal superclass and previous mixins.
    for (var mixin in type.mixins) {
      var superImplemented = _getImplementedInMixin(mixin);
      implemented.addAll(superImplemented);
    }

    // This type overrides everything from its actual superclass.
    addMembers(type);

    _implemented[type] = implemented;
    return implemented;
  }

  /// TODO(scheglov) This repeats a lot of code from [_getImplemented].
  Map<Name, FunctionType> _getImplementedInMixin(InterfaceType type) {
    var implemented = _mixinMembers[type];
    if (implemented != null) {
      return implemented;
    }

    _mixinMembers[type] = const {};
    implemented = <Name, FunctionType>{};

    var libraryUri = type.element.librarySource.uri;

    void addMember(ExecutableElement member) {
      if (!member.isAbstract && !member.isStatic) {
        var name = new Name(libraryUri, member.name);
        implemented[name] = member.type;
      }
    }

    void addMembers(InterfaceType type) {
      type.methods.forEach(addMember);
      type.accessors.forEach(addMember);
    }

    for (var mixin in type.mixins) {
      var superImplemented = _getImplementedInMixin(mixin);
      implemented.addAll(superImplemented);
    }

    // This type overrides everything from its actual superclass.
    addMembers(type);

    _mixinMembers[type] = implemented;
    return implemented;
  }
}

/// The instance interface of an [InterfaceType].
class Interface {
  /// The map of names to their signature in the interface.
  final Map<Name, FunctionType> map;

  /// Each item of this list maps names to their concrete implementations.
  /// The first item of the list is the nominal superclass, next the nominal
  /// superclass plus the first mixin, etc. So, for the class like
  /// `class C extends S with M1, M2`, we get `[S, S&M1, S&M1&M2]`.
  final List<Map<Name, FunctionType>> _supers;

  /// The list of conflicts between superinterfaces - the nominal superclass,
  /// mixins, and interfaces.  Does not include conflicts with the declared
  /// members of the class.
  final List<Conflict> conflicts;

  const Interface._(this.map, this._supers, this.conflicts);
}

/// A public name, or a private name qualified by a library URI.
class Name {
  /// If the name is private, the URI of the defining library.
  /// Otherwise, it is `null`.
  final Uri libraryUri;

  /// The name of this name object.
  /// If the name starts with `_`, then the name is private.
  /// Names of setters end with `=`.
  final String name;

  /// Precomputed
  final bool isPublic;

  /// The cached, pre-computed hash code.
  final int hashCode;

  factory Name(Uri libraryUri, String name) {
    if (name.startsWith('_')) {
      var hashCode = JenkinsSmiHash.hash2(libraryUri.hashCode, name.hashCode);
      return new Name._internal(libraryUri, name, false, hashCode);
    } else {
      return new Name._internal(null, name, true, name.hashCode);
    }
  }

  Name._internal(this.libraryUri, this.name, this.isPublic, this.hashCode);

  @override
  bool operator ==(other) {
    return other is Name &&
        name == other.name &&
        libraryUri == other.libraryUri;
  }

  bool isAccessibleFor(Uri libraryUri) {
    return isPublic || this.libraryUri == libraryUri;
  }

  @override
  String toString() => libraryUri != null ? '$libraryUri::$name' : name;
}
