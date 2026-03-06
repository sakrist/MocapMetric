//
//  Item.swift
//  HurleyMetric
//
//  Created by Volodymyr Boichentsov on 06/03/2026.
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
