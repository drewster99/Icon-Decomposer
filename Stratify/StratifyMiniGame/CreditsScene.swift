//
//  CreditsScene.swift
//  StratifyMiniGame
//
//  Created by Andrew Benson on 10/27/25.
//

import SpriteKit

class CreditsScene: SKScene {

    override func didMove(to view: SKView) {
        backgroundColor = .black

        let creditsLabel = SKLabelNode(fontNamed: "PT Mono")
        creditsLabel.text = "CREDITS 01"
        creditsLabel.fontSize = 48
        creditsLabel.fontColor = .white
        creditsLabel.position = CGPoint(x: size.width / 2, y: size.height / 2)
        addChild(creditsLabel)

        let instructionLabel = SKLabelNode(fontNamed: "PT Mono")
        instructionLabel.text = "CLICK TO START"
        instructionLabel.fontSize = 48
        instructionLabel.fontColor = .gray
        instructionLabel.position = CGPoint(x: size.width / 2, y: size.height / 2 - 90)
        addChild(instructionLabel)

        let blinkAction = SKAction.sequence([
            SKAction.fadeAlpha(to: 0.3, duration: 0.01),
            SKAction.wait(forDuration: 1.0),
            SKAction.fadeAlpha(to: 1.0, duration: 0.01),
            SKAction.wait(forDuration: 2.5)
        ])
        instructionLabel.run(SKAction.repeatForever(blinkAction))
    }

    override func mouseDown(with event: NSEvent) {
        startGame()
    }

    override func keyDown(with event: NSEvent) {
        let spaceKey: UInt16 = 49
        let enterKey: UInt16 = 36
        let returnKey: UInt16 = 76

        if event.keyCode == spaceKey || event.keyCode == enterKey || event.keyCode == returnKey {
            startGame()
        }
    }

    private func startGame() {
        let gameScene = GameScene(size: size)
        gameScene.scaleMode = scaleMode
        let transition = SKTransition.fade(withDuration: 0.5)
        view?.presentScene(gameScene, transition: transition)
    }
}
