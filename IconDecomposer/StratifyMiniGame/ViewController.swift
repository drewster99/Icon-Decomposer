//
//  ViewController.swift
//  StratifyMiniGame
//
//  Created by Andrew Benson on 10/27/25.
//

import Cocoa
import SpriteKit
import GameplayKit

class ViewController: NSViewController {

    @IBOutlet var skView: SKView!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        if let view = self.skView {
            let scene = CreditsScene(size: CGSize(width: 800, height: 600))
            scene.scaleMode = .aspectFill

            view.presentScene(scene)
            view.ignoresSiblingOrder = true

            view.showsFPS = true
            view.showsNodeCount = true
        }
    }
}

