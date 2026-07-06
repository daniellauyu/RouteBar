//
//  Item.swift
//  RouteBar
//
//  Created by DANIEL LAU on 2026/7/6.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
