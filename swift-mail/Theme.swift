//
//  Theme.swift
//  swift-mail
//

import SwiftUI

/// Shared design tokens.
///
/// Every metric in the app used to be a magic literal inlined at its call
/// site. Centralizing them here means a spacing or radius change is one edit
/// instead of a search-and-hope across every view, and it gives new views a
/// scale to reach for instead of a new arbitrary number.
enum Theme {
    /// A 4pt scale, matching the increments already in use throughout the app.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
    }

    enum Size {
        static let avatar: CGFloat = 36
        static let unreadDot: CGFloat = 8
        /// Width of the trailing-aligned label column in a compose field row.
        static let fieldLabel: CGFloat = 56
    }

    /// `(min, ideal)` pairs for `NavigationSplitView` column widths.
    enum Column {
        static let sidebar = (min: 180.0, ideal: 220.0)
        static let list = (min: 280.0, ideal: 340.0)
        static let detail = (min: 420.0, ideal: 680.0)
    }

    enum Motion {
        static let hover = Animation.easeOut(duration: 0.12)
    }
}
