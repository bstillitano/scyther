//
//  ScytherBootstrap.h
//
//
//  Created by Brandon Stillitano on 26/10/26.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Whether the `NSURLSessionConfiguration` hooks were installed when this image loaded.
///
/// The hooks are installed by a constructor that runs before any host code, which is what lets a
/// session created before `Scyther.start()` still carry `HTTPInterceptorURLProtocol`. Scyther calls
/// this from `start()` for two reasons:
///
/// - It forces the linker to keep this object file. A static library member that nothing
///   references is dropped, and its constructor with it, which would silently leave every session
///   unintercepted.
/// - It lets a debug build assert that the constructor actually ran.
///
/// - Returns: `true` once the hooks are in place.
bool ScytherBootstrapIsInstalled(void);

NS_ASSUME_NONNULL_END
