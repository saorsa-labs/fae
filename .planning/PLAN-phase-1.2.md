# Phase 1.2: Refactor ApprovalOverlay into InputOverlay

## Goal
Extract input-request and governance UI from ApprovalOverlayController/View.
Delete all approval card UI (ApprovalCard, BatchApprovalCard, ManualApprovalCard, DisasterWarningCard).
Keep: InputCard, FormInputCard, ToolModeCard, GovernanceConfirmationCard.
Rename controller to InputOverlayController, view to InputOverlayView.

## Tasks

### Task 1: Create InputOverlayController from ApprovalOverlayController
- Copy ApprovalOverlayController.swift to InputOverlayController.swift
- Remove: activeApproval, activeBatchApproval properties
- Remove: ApprovalRequest struct, BatchApprovalDisplayRequest struct
- Remove: approve(), deny(), approveAlways(), approveBatch(), denyBatch() methods
- Remove: handleRequested(), handleBatchRequested(), formatDescription() methods
- Remove: faeApprovalRequested, faeApprovalResolved, faeBatchApprovalRequested observers
- Remove: faeApprovalRespond notification name extension
- Keep: activeInput, activeToolModeRequest, activeGovernanceConfirmation
- Keep: InputField, InputRequest, ToolModeRequest, GovernanceConfirmationRequest structs
- Keep: submitInput(), submitForm(), cancelInput(), upgradeToolMode(), requestEnrollment(), etc.
- Keep: handleInputRequired(), handleToolModeUpgradeRequested(), handleGovernanceConfirmationRequested()
- Keep: faeInputRequired, faeInputResponse, faeToolModeUpgrade*, faeGovernanceConfirmation* observers
- Files: Sources/Fae/InputOverlayController.swift (NEW)

### Task 2: Create InputOverlayView from ApprovalOverlayView
- Copy ApprovalOverlayView.swift to InputOverlayView.swift
- Rename struct to InputOverlayView, use InputOverlayController
- Remove: ApprovalCard, ManualApprovalCard, DisasterWarningCard, BatchApprovalCard views
- Remove: approval-related branches from body (activeApproval, activeBatchApproval)
- Remove: animation values for activeApproval, activeBatchApproval
- Keep: InputCard, FormInputCard, ToolModeCard, GovernanceConfirmationCard
- Keep: DismissOverlayButton
- Files: Sources/Fae/InputOverlayView.swift (NEW)

### Task 3: Update FaeApp.swift to use InputOverlayController
- Replace `ApprovalOverlayController()` with `InputOverlayController()`
- Rename property from `approvalOverlay` to `inputOverlay`
- Update all references within FaeApp.swift
- Files: Sources/Fae/FaeApp.swift

### Task 4: Update AuxiliaryWindowManager to use InputOverlayController/View
- Rename `approvalController` property to `inputController`
- Update `makeApprovalPanel` to use InputOverlayController/InputOverlayView
- Update type references
- Files: Sources/Fae/AuxiliaryWindowManager.swift

### Task 5: Update FaeLocalRuntimeServer to use InputOverlayController
- Change `approvalOverlay: ApprovalOverlayController` to `inputOverlay: InputOverlayController`
- Remove activeApproval references (approval polling no longer needed)
- Keep activeInput references (rewire to inputOverlay)
- Files: Sources/Fae/Runtime/FaeLocalRuntimeServer.swift

### Task 6: Update TestServer to use InputOverlayController
- Change `approvalOverlay: ApprovalOverlayController` to `inputOverlay: InputOverlayController`
- Remove approval-related status code (approvalToolName, approvalRequestID)
- Keep input-related code (activeInput, submitInput, submitForm, cancelInput)
- Update serializeInputRequest to use InputOverlayController.InputRequest
- Files: Sources/Fae/TestServer.swift

### Task 7: Update remaining references (BackendEventRouter, HostCommandBridge, BuiltinTools)
- BackendEventRouter: remove approval notification posts, keep input/toolMode/governance
- HostCommandBridge: remove approval references if any
- BuiltinTools: update doc comment referencing ApprovalOverlayController
- Files: Sources/Fae/BackendEventRouter.swift, Sources/Fae/HostCommandBridge.swift, Sources/Fae/Tools/BuiltinTools.swift

### Task 8: Delete old files and remove approval notification names
- Delete ApprovalOverlayController.swift
- Delete ApprovalOverlayView.swift
- Remove faeApprovalRequested, faeApprovalResolved notification name definitions from BackendEventRouter
- Remove faeBatchApprovalRequested, faeBatchApprovalRespond notification name definitions
- Remove any code that posts these deleted notifications
- Keep faeInputRequired, faeInputResponse, faeToolModeUpgrade*, faeGovernanceConfirmation* names
- Files: Sources/Fae/ApprovalOverlayController.swift (DELETE), Sources/Fae/ApprovalOverlayView.swift (DELETE), Sources/Fae/BackendEventRouter.swift

### Task 9: Build validation
- Run `just build` from native/macos/Fae/
- Fix any remaining references to deleted types
- Note: full `just check` will fail due to Phase 1.3 pending work — build-only is expected to have errors from deleted files in Phase 1.1
