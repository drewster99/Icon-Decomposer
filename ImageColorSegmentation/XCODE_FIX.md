# Xcode Not Showing Files - Quick Fix

This is a known Xcode bug with Swift Packages. Try these solutions in order:

## Solution 1: Navigator Selection
**Most common fix** - The navigator might be on the wrong item:

1. In Xcode's left sidebar (Navigator), click the **folder icon** at the top (Project Navigator)
2. You should see a hierarchy like:
   ```
   ImageColorSegmentation
   ├─ Sources
   │  ├─ ImageColorSegmentation
   │  └─ ImageColorSegmentationDemo
   ├─ Tests
   └─ Package.swift
   ```

## Solution 2: Close & Reopen
1. Close Xcode completely (⌘Q)
2. From terminal:
   ```bash
   cd ImageColorSegmentation
   rm -rf .build .swiftpm
   xed .
   ```

## Solution 3: Clear Derived Data
1. Close Xcode
2. Terminal:
   ```bash
   rm -rf ~/Library/Developer/Xcode/DerivedData/*
   ```
3. Reopen:
   ```bash
   xed .
   ```

## Solution 4: File → Open (Fresh)
1. Close Xcode
2. Open Xcode (don't open any project)
3. File → Open
4. Navigate to `ImageColorSegmentation` **folder** (not Package.swift)
5. Click "Open"

## Solution 5: Reset and Build
Sometimes Xcode needs to build before showing files:

```bash
cd ImageColorSegmentation
rm -rf .build .swiftpm
swift package clean
swift package resolve
xed .
```

Then in Xcode: **⌘B** (Build)

## Solution 6: Manual Navigation
If navigator is empty but you can build:

1. Press **⌘1** (show Project Navigator)
2. Click on "ImageColorSegmentation" at the top of the navigator
3. Press **⌘⇧O** (Open Quickly) and type a filename
4. Or use: Editor → Show Project Navigator

## Solution 7: Check Filter
At the bottom of the navigator pane:

1. Look for a filter text box
2. Make sure it's empty or showing "Recent"
3. Try clicking the filter icon and selecting "Show All Files"

## Verification

If Xcode is working correctly, you should see:

**Project Navigator (⌘1):**
```
▼ ImageColorSegmentation
  ▼ Sources
    ▼ ImageColorSegmentation
      - DataType.swift
      - ImagePipeline.swift
      - Operations.swift
      - PipelineOperation.swift
    ▼ ImageColorSegmentationDemo
      - main.swift
  ▼ Tests
    ▼ ImageColorSegmentationTests
      - PipelineBranchingTests.swift
      - PipelineConfigurationTests.swift
      - PipelineExecutionTests.swift
  - Package.swift
  - README.md
```

## Still Not Working?

**Quick workaround**: Use command-line tools instead:

```bash
# Build
swift build

# Test
swift test

# Run demo
swift run ImageColorSegmentationDemo

# Edit files in VS Code or another editor
code .
```

Or just **edit files directly** - Xcode will detect changes even if the navigator is broken!

## Nuclear Option: Generate Xcode Project

⚠️ Not recommended (deprecated), but works:

```bash
swift package generate-xcodeproj
open ImageColorSegmentation.xcodeproj
```

Note: This creates a `.xcodeproj` that can get out of sync with `Package.swift`.
