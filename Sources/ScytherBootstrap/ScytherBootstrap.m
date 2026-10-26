//
//  ScytherBootstrap.m
//
//
//  Created by Brandon Stillitano on 26/10/26.
//

#import "ScytherBootstrap.h"
#import <objc/runtime.h>
#import <stdatomic.h>

// Hooks every way a host app creates an `NSURLSessionConfiguration`, so that each configuration
// carries `HTTPInterceptorURLProtocol` from the moment it exists.
//
// This has to happen at image load rather than in `Scyther.start()`. A session copies its
// configuration when it is created and never reads it again, so a session the host built before
// `start()` could never be intercepted, however early `start()` was called. The protocol itself is
// inert until Scyther starts: its `canInit` returns `false` while `Scyther.isStarted` is `false`.
//
// Swift has no `+load`, which is why this lives in an Objective-C target.

/// The runtime name of the interceptor. Resolved lazily, because Swift class metadata is not
/// guaranteed to be usable while image constructors run.
static NSString *const ScytherInterceptorClassName = @"Scyther.HTTPInterceptorURLProtocol";

/// The value of `String.noSwizzle`. A background configuration whose identifier contains it is
/// left alone.
static NSString *const ScytherNoSwizzleMarker = @"do_not_swizzle";

/// The interceptor class once it has been found, stored as an address so it can be atomic.
static _Atomic(uintptr_t) ScytherInterceptorClassAddress = 0;

/// Set once the constructor has installed every hook.
static atomic_bool ScytherHooksInstalled = false;

/// The original implementations. Written once by the constructor, before any host code can create
/// a configuration, and only read afterwards.
static IMP ScytherOriginalDefault = NULL;
static IMP ScytherOriginalEphemeral = NULL;
static IMP ScytherOriginalBackground = NULL;
static IMP ScytherOriginalInit = NULL;

/// Returns the interceptor class, or `Nil` if Swift has not made it available yet. A miss is not
/// cached, so the next configuration tries again.
static Class ScytherInterceptorClass(void) {
    uintptr_t address = atomic_load_explicit(&ScytherInterceptorClassAddress, memory_order_acquire);
    if (address != 0) {
        return (__bridge Class)(void *)address;
    }
    Class interceptor = NSClassFromString(ScytherInterceptorClassName);
    if (interceptor != Nil) {
        atomic_store_explicit(&ScytherInterceptorClassAddress,
                              (uintptr_t)(__bridge void *)interceptor,
                              memory_order_release);
    }
    return interceptor;
}

/// Puts the interceptor first in a configuration's protocol classes, unless it is already there.
/// A configuration with no list at all — what `-init` returns — is left without one, because a list
/// holding only the interceptor would stand in for the system's own protocols.
static void ScytherIntercept(NSURLSessionConfiguration *configuration) {
    Class interceptor = ScytherInterceptorClass();
    NSArray<Class> *classes = configuration.protocolClasses;
    if (interceptor == Nil || classes == nil || [classes containsObject:interceptor]) {
        return;
    }
    NSMutableArray<Class> *updated = [classes mutableCopy];
    [updated insertObject:interceptor atIndex:0];
    configuration.protocolClasses = updated;
}

/// Takes the interceptor back out of a configuration, for the `noSwizzle` opt-out. `-init` runs
/// inside the original background getter, so the interceptor may already be there.
static void ScytherStopIntercepting(NSURLSessionConfiguration *configuration) {
    Class interceptor = ScytherInterceptorClass();
    NSArray<Class> *classes = configuration.protocolClasses;
    if (interceptor == Nil || ![classes containsObject:interceptor]) {
        return;
    }
    NSMutableArray<Class> *updated = [classes mutableCopy];
    [updated removeObject:interceptor];
    configuration.protocolClasses = updated;
}

// MARK: - Replacements

typedef NSURLSessionConfiguration *(*ScytherGetterIMP)(id, SEL);
typedef NSURLSessionConfiguration *(*ScytherBackgroundIMP)(id, SEL, NSString *);

/// `-init` consumes its receiver and returns a retained object. The pointer type says so, so that
/// ARC balances the call to the original exactly as it would a real `init`.
typedef id (*ScytherInitIMP)(id __attribute__((ns_consumed)), SEL) __attribute__((ns_returns_retained));

static NSURLSessionConfiguration *ScytherDefault(id self, SEL _cmd) {
    NSURLSessionConfiguration *configuration = ((ScytherGetterIMP)ScytherOriginalDefault)(self, _cmd);
    ScytherIntercept(configuration);
    return configuration;
}

static NSURLSessionConfiguration *ScytherEphemeral(id self, SEL _cmd) {
    NSURLSessionConfiguration *configuration = ((ScytherGetterIMP)ScytherOriginalEphemeral)(self, _cmd);
    ScytherIntercept(configuration);
    return configuration;
}

static NSURLSessionConfiguration *ScytherBackground(id self, SEL _cmd, NSString *identifier) {
    NSURLSessionConfiguration *configuration = ((ScytherBackgroundIMP)ScytherOriginalBackground)(self, _cmd, identifier);
    if ([identifier containsString:ScytherNoSwizzleMarker]) {
        ScytherStopIntercepting(configuration);
    } else {
        ScytherIntercept(configuration);
    }
    return configuration;
}

/// Covers `+new` and `alloc`/`init` alike: `NSURLSessionConfiguration` implements `-init` itself,
/// and `+new` goes through it.
static id ScytherInit(id __attribute__((ns_consumed)) self, SEL _cmd) __attribute__((ns_returns_retained)) {
    id configuration = ((ScytherInitIMP)ScytherOriginalInit)(self, _cmd);
    if ([configuration isKindOfClass:[NSURLSessionConfiguration class]]) {
        ScytherIntercept(configuration);
    }
    return configuration;
}

// MARK: - Installation

/// Replaces a method that `cls` implements itself, returning the original. An inherited method is
/// never replaced, because that would change it for every class that inherits it.
static IMP ScytherReplace(Class cls, SEL selector, IMP replacement) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method own = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            own = methods[index];
            break;
        }
    }
    free(methods);
    return own == NULL ? NULL : method_setImplementation(own, replacement);
}

/// Runs once, when the image loads and before any host code. It touches nothing but the Objective-C
/// runtime: no Swift type, and none of Scyther's main-actor state.
__attribute__((constructor))
static void ScytherBootstrapInstall(void) {
    Class configurationClass = [NSURLSessionConfiguration class];
    Class metaclass = object_getClass(configurationClass);

    ScytherOriginalDefault = ScytherReplace(metaclass, @selector(defaultSessionConfiguration), (IMP)ScytherDefault);
    ScytherOriginalEphemeral = ScytherReplace(metaclass, @selector(ephemeralSessionConfiguration), (IMP)ScytherEphemeral);
    ScytherOriginalBackground = ScytherReplace(metaclass, @selector(backgroundSessionConfigurationWithIdentifier:), (IMP)ScytherBackground);
    ScytherOriginalInit = ScytherReplace(configurationClass, @selector(init), (IMP)ScytherInit);

    bool installed = ScytherOriginalDefault != NULL
        && ScytherOriginalEphemeral != NULL
        && ScytherOriginalBackground != NULL
        && ScytherOriginalInit != NULL;
    atomic_store(&ScytherHooksInstalled, installed);
}

bool ScytherBootstrapIsInstalled(void) {
    return atomic_load(&ScytherHooksInstalled);
}
