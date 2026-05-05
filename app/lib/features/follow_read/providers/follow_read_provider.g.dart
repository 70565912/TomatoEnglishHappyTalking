// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'follow_read_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$followReadHash() => r'bc32263daca55f343ddc1a5e01a08ab88fdd9680';

/// Copied from Dart SDK
class _SystemHash {
  _SystemHash._();

  static int combine(int hash, int value) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + value);
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    return hash ^ (hash >> 6);
  }

  static int finish(int hash) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    // ignore: parameter_assignments
    hash = hash ^ (hash >> 11);
    return 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
  }
}

abstract class _$FollowRead
    extends BuildlessAutoDisposeAsyncNotifier<FollowReadState> {
  late final int articleId;

  FutureOr<FollowReadState> build(
    int articleId,
  );
}

/// See also [FollowRead].
@ProviderFor(FollowRead)
const followReadProvider = FollowReadFamily();

/// See also [FollowRead].
class FollowReadFamily extends Family<AsyncValue<FollowReadState>> {
  /// See also [FollowRead].
  const FollowReadFamily();

  /// See also [FollowRead].
  FollowReadProvider call(
    int articleId,
  ) {
    return FollowReadProvider(
      articleId,
    );
  }

  @override
  FollowReadProvider getProviderOverride(
    covariant FollowReadProvider provider,
  ) {
    return call(
      provider.articleId,
    );
  }

  static const Iterable<ProviderOrFamily>? _dependencies = null;

  @override
  Iterable<ProviderOrFamily>? get dependencies => _dependencies;

  static const Iterable<ProviderOrFamily>? _allTransitiveDependencies = null;

  @override
  Iterable<ProviderOrFamily>? get allTransitiveDependencies =>
      _allTransitiveDependencies;

  @override
  String? get name => r'followReadProvider';
}

/// See also [FollowRead].
class FollowReadProvider
    extends AutoDisposeAsyncNotifierProviderImpl<FollowRead, FollowReadState> {
  /// See also [FollowRead].
  FollowReadProvider(
    int articleId,
  ) : this._internal(
          () => FollowRead()..articleId = articleId,
          from: followReadProvider,
          name: r'followReadProvider',
          debugGetCreateSourceHash:
              const bool.fromEnvironment('dart.vm.product')
                  ? null
                  : _$followReadHash,
          dependencies: FollowReadFamily._dependencies,
          allTransitiveDependencies:
              FollowReadFamily._allTransitiveDependencies,
          articleId: articleId,
        );

  FollowReadProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.articleId,
  }) : super.internal();

  final int articleId;

  @override
  FutureOr<FollowReadState> runNotifierBuild(
    covariant FollowRead notifier,
  ) {
    return notifier.build(
      articleId,
    );
  }

  @override
  Override overrideWith(FollowRead Function() create) {
    return ProviderOverride(
      origin: this,
      override: FollowReadProvider._internal(
        () => create()..articleId = articleId,
        from: from,
        name: null,
        dependencies: null,
        allTransitiveDependencies: null,
        debugGetCreateSourceHash: null,
        articleId: articleId,
      ),
    );
  }

  @override
  AutoDisposeAsyncNotifierProviderElement<FollowRead, FollowReadState>
      createElement() {
    return _FollowReadProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is FollowReadProvider && other.articleId == articleId;
  }

  @override
  int get hashCode {
    var hash = _SystemHash.combine(0, runtimeType.hashCode);
    hash = _SystemHash.combine(hash, articleId.hashCode);

    return _SystemHash.finish(hash);
  }
}

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
mixin FollowReadRef on AutoDisposeAsyncNotifierProviderRef<FollowReadState> {
  /// The parameter `articleId` of this provider.
  int get articleId;
}

class _FollowReadProviderElement
    extends AutoDisposeAsyncNotifierProviderElement<FollowRead, FollowReadState>
    with FollowReadRef {
  _FollowReadProviderElement(super.provider);

  @override
  int get articleId => (origin as FollowReadProvider).articleId;
}
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
