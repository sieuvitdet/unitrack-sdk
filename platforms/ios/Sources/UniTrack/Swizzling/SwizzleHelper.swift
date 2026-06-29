// SwizzleHelper.swift
//
// Idempotent method-swizzle utilities. The naive `method_exchangeImplementations`
// pattern is NOT idempotent: calling it twice un-swizzles (swaps back). When two
// modules of the SDK end up linked into the same process (e.g. a host app
// embedding both the SPM target AND a Flutter/RN plugin that bundles UniTrack)
// each module's `static let installed` initializer fires once — but TWO calls
// land on UIKit. The second call would silently revert the first.
//
// The fix mirrors what ViewControllerSwizzler has always done:
//
//   1. Try `class_addMethod(cls, originalSel, replacementIMP, ...)`.
//      If the class doesn't yet declare the original selector directly (it
//      inherits it from a superclass) this ADDS a new method slot pointing at
//      our replacement and returns true. We then `class_replaceMethod` on the
//      replacement selector to point at the original superclass IMP — so
//      `self.ut_*` (which dispatches through the replacement selector) still
//      reaches the real UIKit implementation.
//   2. Otherwise fall back to `method_exchangeImplementations`. This branch
//      only runs the FIRST time across the process — any subsequent attempt
//      will hit branch 1's `class_addMethod` returning false because the
//      replacement IMP is now already installed.
//
// Net effect: calling `swizzleInstanceMethod` or `swizzleClassMethod` from N
// independent modules is safe — the first installs, the rest no-op.

import ObjectiveC.runtime

enum SwizzleHelper {

    /// Idempotent instance-method swizzle. See file header for the dispatch rules.
    static func swizzleInstanceMethod(cls: AnyClass,
                                      original: Selector,
                                      replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(cls, original),
              let replacementMethod = class_getInstanceMethod(cls, replacement) else { return }

        let added = class_addMethod(cls, original,
                                    method_getImplementation(replacementMethod),
                                    method_getTypeEncoding(replacementMethod))
        if added {
            class_replaceMethod(cls, replacement,
                                method_getImplementation(originalMethod),
                                method_getTypeEncoding(originalMethod))
        } else {
            method_exchangeImplementations(originalMethod, replacementMethod)
        }
    }

    /// Idempotent class-method swizzle. Class methods live on the meta-class so
    /// the same logic applies — we just look them up via `class_getClassMethod`
    /// and operate on the meta-class for `class_addMethod`/`class_replaceMethod`.
    static func swizzleClassMethod(cls: AnyClass,
                                   original: Selector,
                                   replacement: Selector) {
        guard let originalMethod = class_getClassMethod(cls, original),
              let replacementMethod = class_getClassMethod(cls, replacement) else { return }
        // The meta-class is the "class of a class" — that's where class methods
        // are actually stored. Without the cast `class_addMethod` would target
        // the instance method table and silently miss.
        guard let metaCls = object_getClass(cls) else { return }

        let added = class_addMethod(metaCls, original,
                                    method_getImplementation(replacementMethod),
                                    method_getTypeEncoding(replacementMethod))
        if added {
            class_replaceMethod(metaCls, replacement,
                                method_getImplementation(originalMethod),
                                method_getTypeEncoding(originalMethod))
        } else {
            method_exchangeImplementations(originalMethod, replacementMethod)
        }
    }
}
