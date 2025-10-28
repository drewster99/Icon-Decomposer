//
//  CreditsScene.swift
//  Stratify
//
//  Created by Andrew Benson on 10/27/25.
//

import SpriteKit

class CreditsScene: SKScene {
    enum Mode {
        case normal
        case attract
    }

    private var creditsLabel: SKLabelNode?
    private var instructionLabel: SKLabelNode?
    private var mode: Mode
    private var isShowingInsertCoin = false
    private var credits: Int {
        get {
            UserDefaults.standard.integer(forKey: "StratifyMinigameCredits")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "StratifyMinigameCredits")
            updateCreditsDisplay()
        }
    }
    private var freePlayTimer: TimeInterval = 0
    private let freePlayDelay: TimeInterval = 45.0

    init(size: CGSize, mode: Mode = .normal) {
        self.mode = mode
        super.init(size: size)
    }

    required init?(coder aDecoder: NSCoder) {
        self.mode = .normal
        super.init(coder: aDecoder)
    }

    override func didMove(to view: SKView) {
        backgroundColor = .black

        let label = SKLabelNode(fontNamed: "PT Mono")
        label.fontSize = 48
        label.fontColor = .white
        label.position = CGPoint(x: size.width / 2, y: size.height / 2)
        label.name = "creditsLabel"
        addChild(label)
        creditsLabel = label

        switch mode {
        case .normal:
            setupNormalMode()
        case .attract:
            setupAttractMode()
        }
    }

    private func setupNormalMode() {
        updateCreditsDisplay()

        let instruction = SKLabelNode(fontNamed: "PT Mono")
        instruction.text = "CLICK TO START"
        instruction.fontSize = 48
        instruction.fontColor = .gray
        instruction.position = CGPoint(x: size.width / 2, y: size.height / 2 - 90)
        addChild(instruction)
        instructionLabel = instruction

        let blinkAction = SKAction.sequence([
            SKAction.fadeAlpha(to: 0.3, duration: 0.01),
            SKAction.wait(forDuration: 1.0),
            SKAction.fadeAlpha(to: 1.0, duration: 0.01),
            SKAction.wait(forDuration: 2.5)
        ])
        instruction.run(SKAction.repeatForever(blinkAction))
    }

    private func updateCreditsDisplay() {
        let displayCredits = String(format: "%02d", min(credits, 99))
        creditsLabel?.text = "CREDITS \(displayCredits)"
    }

    private func setupAttractMode() {
        creditsLabel?.text = "CREDITS 00"

        let alternateAction = SKAction.sequence([
            SKAction.wait(forDuration: 1.5),
            SKAction.run { [weak self] in
                self?.toggleAttractText()
            }
        ])
        run(SKAction.repeatForever(alternateAction))
    }

    private func toggleAttractText() {
        isShowingInsertCoin.toggle()
        creditsLabel?.text = isShowingInsertCoin ? "INSERT COIN" : "CREDITS 00"
    }

    override func mouseDown(with event: NSEvent) {
        if mode == .normal {
            startGame()
        }
    }

    override func keyDown(with event: NSEvent) {
        let spaceKey: UInt16 = 49
        let enterKey: UInt16 = 36
        let returnKey: UInt16 = 76
        let cKey: UInt16 = 8

        if event.keyCode == cKey {
            addCredit()
        } else if mode == .normal && (event.keyCode == spaceKey || event.keyCode == enterKey || event.keyCode == returnKey) {
            startGame()
        }
    }

    private func addCredit() {
        if credits < 99 {
            credits += 1
            NSSound.beep()

            if mode == .attract && credits > 0 {
                exitAttractMode()
            }
        }
    }

    private func exitAttractMode() {
        removeAllActions()
        mode = .normal
        freePlayTimer = 0

        updateCreditsDisplay()

        let instruction = SKLabelNode(fontNamed: "PT Mono")
        instruction.text = "CLICK TO START"
        instruction.fontSize = 48
        instruction.fontColor = .gray
        instruction.position = CGPoint(x: size.width / 2, y: size.height / 2 - 90)
        addChild(instruction)
        instructionLabel = instruction

        let blinkAction = SKAction.sequence([
            SKAction.fadeAlpha(to: 0.3, duration: 0.01),
            SKAction.wait(forDuration: 1.0),
            SKAction.fadeAlpha(to: 1.0, duration: 0.01),
            SKAction.wait(forDuration: 2.5)
        ])
        instruction.run(SKAction.repeatForever(blinkAction))
    }

    private func startGame() {
        guard credits > 0 else { return }

        credits -= 1
        updateCreditsDisplay()
        NSSound.beep()

        let wait = SKAction.wait(forDuration: 0.3)
        let transition = SKAction.run { [weak self] in
            guard let self = self else { return }
            let gameScene = GameScene(size: self.size)
            gameScene.scaleMode = self.scaleMode
            let transition = SKTransition.fade(withDuration: 0.5)
            self.view?.presentScene(gameScene, transition: transition)
        }
        run(SKAction.sequence([wait, transition]))
    }

    override func update(_ currentTime: TimeInterval) {
        if mode == .attract && credits == 0 {
            freePlayTimer += 1.0 / 60.0

            if freePlayTimer >= freePlayDelay {
                credits = 1
                freePlayTimer = 0
            }
        }
    }
}
