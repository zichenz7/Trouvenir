import AVFoundation
import CoreLocation
import PhotosUI
import Speech
import SwiftUI
import UIKit
import WebKit

@main
struct TrouvenirApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private enum RootAppTab: String {
    case create
    case collection
    case identity
}

private enum TrouvenirAPIEnvironment {
    private static let localBridgeBaseURL = URL(string: "http://127.0.0.1:3000")!
    private static let productionBridgeBaseURL = URL(string: "https://trouvenir-api.onrender.com")!

    static var bridgeBaseURL: URL {
        if let value = ProcessInfo.processInfo.environment["TROUVENIR_BRIDGE_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty,
           let url = URL(string: value) {
            return url
        }

        #if DEBUG
        return localBridgeBaseURL
        #else
        return productionBridgeBaseURL
        #endif
    }

    static var memoryAIBaseURL: URL {
        bridgeBaseURL.appending(path: "api/ai")
    }

    static var tripoBaseURL: URL {
        bridgeBaseURL.appending(path: "api/tripo")
    }

    static var appDiagnosticsURL: URL? {
        #if DEBUG
        localBridgeBaseURL.appending(path: "debug/app-log")
        #else
        nil
        #endif
    }

    static var renderDiagnosticsURL: URL? {
        #if DEBUG
        localBridgeBaseURL.appending(path: "debug/render-log")
        #else
        nil
        #endif
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var memories: [MemoryProject] = []
    @State private var selectedTab: RootAppTab = .create
    @State private var debugModelViewerURL: URL?
    @State private var didOpenDebugModel = false
    private let tripoClient = TripoAPIClient()

    var body: some View {
        TabView(selection: $selectedTab) {
            MemoryStudioView(
                memories: $memories,
                openCollection: {
                    withAnimation(.snappy) {
                        selectedTab = .collection
                    }
                }
            )
                .tabItem {
                    Label("创造", systemImage: "sparkles")
                }
                .tag(RootAppTab.create)

            CollectionView(memories: memories)
                .tabItem {
                    Label("收藏馆", systemImage: "square.grid.2x2.fill")
                }
                .tag(RootAppTab.collection)

            IdentityView(memories: memories)
                .tabItem {
                    Label("我的", systemImage: "person.crop.circle")
                }
                .tag(RootAppTab.identity)
        }
        .tint(.trouvenirTeal)
        .sheet(
            isPresented: Binding(
                get: { debugModelViewerURL != nil },
                set: { isPresented in
                    if !isPresented {
                        debugModelViewerURL = nil
                    }
                }
            )
        ) {
            if let debugModelViewerURL {
                ModelViewerSheet(modelURL: debugModelViewerURL)
            }
        }
        .onAppear {
            AppDiagnostics.shared.record(
                "app.appear",
                data: [
                    "memoryCount": memories.count,
                    "appLogPath": AppDiagnostics.shared.localLogPath
                ]
            )
            seedDebugMemoriesIfRequested()
            runDebugLocationChecksIfRequested()
            openDebugModelIfRequested()
        }
        .onChange(of: selectedTab) { _, tab in
            AppDiagnostics.shared.record(
                "app.tab.changed",
                data: ["tab": tab.rawValue]
            )
            ModelRenderDiagnostics.shared.record(
                "app.tab.changed",
                data: ["tab": tab.rawValue]
            )
        }
        .onChange(of: scenePhase) { _, phase in
            AppDiagnostics.shared.record(
                "app.scenePhase.changed",
                data: ["phase": String(describing: phase)]
            )
        }
    }

    private func seedDebugMemoriesIfRequested() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard let destination = environment["TROUVENIR_DEBUG_SEED_MEMORY_DESTINATION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !destination.isEmpty,
              !memories.contains(where: { $0.destination == destination }) else {
            return
        }

        let title = environment["TROUVENIR_DEBUG_SEED_MEMORY_TITLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let seededMemory = MemoryProject(
            title: title?.isEmpty == false ? title! : "\(destination)旅行记忆",
            destination: destination,
            identityTitle: "\(destination)收藏家",
            companions: "调试用户",
            photoCount: 1,
            walkingDistance: "待补充",
            duration: "待补充",
            storyTitle: "《\(String(destination.prefix(8)))的回声》",
            story: "这是一段用于复现城市与国家归属问题的 Debug 旅行记忆。",
            souvenirs: [
                GeneratedSouvenir(
                    name: "\(destination)纪念章",
                    caption: "用于定位归属诊断",
                    symbol: "mappin.and.ellipse",
                    color: .trouvenirTeal
                )
            ],
            accent: .trouvenirTeal
        )
        memories.append(seededMemory)
        AppDiagnostics.shared.record(
            "debug.memory.seeded",
            data: [
                "destination": destination,
                "memoryCount": memories.count
            ]
        )
        #endif
    }

    private func runDebugLocationChecksIfRequested() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["TROUVENIR_DEBUG_RUN_LOCATION_CHECKS"] == "1" else {
            return
        }

        let checks = [
            (input: "Alcatraz Island", city: "旧金山", country: "美国"),
            (input: "Newport Beach", city: "Newport Beach", country: "美国"),
            (input: "好莱坞环球影城", city: "洛杉矶", country: "美国"),
            (input: "Golden Gate Bridge", city: "旧金山", country: "美国"),
            (input: "东京塔", city: "东京", country: "日本")
        ]

        for check in checks {
            let resolution = TravelArchive.resolveLocation(for: check.input)
            let passed = resolution.cityName == check.city && resolution.countryName == check.country
            AppDiagnostics.shared.record(
                "debug.location.check",
                level: passed ? "info" : "error",
                data: [
                    "input": check.input,
                    "expectedCity": check.city,
                    "actualCity": resolution.cityName,
                    "expectedCountry": check.country,
                    "actualCountry": resolution.countryName ?? "",
                    "rule": resolution.rule,
                    "passed": passed
                ],
                dedupeKey: "debug.location.check:\(check.input):\(passed)"
            )
        }
        #endif
    }

    private func openDebugModelIfRequested() {
        #if DEBUG
        guard !didOpenDebugModel else { return }
        didOpenDebugModel = true

        let environment = ProcessInfo.processInfo.environment
        if let proxiedValue = environment["TROUVENIR_DEBUG_PROXIED_MODEL_URL"],
           let proxiedURL = URL(string: proxiedValue) {
            ModelRenderDiagnostics.shared.recordModelOpen(
                source: "debug_launch_proxied",
                modelURL: proxiedURL,
                proxiedURL: proxiedURL
            )
            debugModelViewerURL = proxiedURL
            return
        }

        if let modelValue = environment["TROUVENIR_DEBUG_MODEL_URL"],
           let modelURL = URL(string: modelValue) {
            let proxiedURL = tripoClient.proxiedModelURL(for: modelURL)
            ModelRenderDiagnostics.shared.recordModelOpen(
                source: "debug_launch",
                modelURL: modelURL,
                proxiedURL: proxiedURL
            )
            debugModelViewerURL = proxiedURL
        }
        #endif
    }
}

enum CreationStage: Int, CaseIterable {
    case memory
    case subject
    case model

    var title: String {
        switch self {
        case .memory:
            return "描述"
        case .subject:
            return "确认"
        case .model:
            return "生成"
        }
    }

    var subtitle: String {
        switch self {
        case .memory:
            return "用一句话说清楚这次旅行"
        case .subject:
            return "默认生成人物主体"
        case .model:
            return "完成后进入收藏馆"
        }
    }
}

struct MemoryStudioView: View {
    @Binding var memories: [MemoryProject]
    let openCollection: () -> Void

    @State private var creationStage: CreationStage = .memory
    @State private var memoryPrompt = ""
    @State private var showAdvancedTripDetails = false
    @State private var showAdvancedSubjectOptions = false
    @State private var notifyWhenModelReady = true
    @State private var completionMessage: String?
    @State private var memoryError: String?
    @State private var destination = ""
    @State private var tripTitle = ""
    @State private var companions = ""
    @State private var feeling = ""
    @State private var tripoSubjectCategory = "人物"
    @State private var tripoSubjectDetail = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var generatedMemory: MemoryProject?
    @State private var isGeneratingMemory = false
    @State private var isGenerating3D = false
    @State private var progress = 0.0
    @State private var currentStep = "等待上传旅行线索"
    @State private var tripoTask: TripoTask?
    @State private var tripoError: String?
    @State private var modelViewerURL: URL?

    private let tripoClient = TripoAPIClient()
    private let memoryAIClient = MemoryAIClient()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HeroHeader()

                    CreationStepHeader(stage: creationStage)

                    switch creationStage {
                    case .memory:
                        MemoryPromptStep(
                            prompt: $memoryPrompt,
                            destination: $destination,
                            tripTitle: $tripTitle,
                            companions: $companions,
                            feeling: $feeling,
                            selectedItems: $selectedItems,
                            showAdvanced: $showAdvancedTripDetails,
                            isGenerating: isGeneratingMemory,
                            progress: progress,
                            currentStep: currentStep,
                            errorMessage: memoryError,
                            action: {
                                Task {
                                    await generateMemory()
                                }
                            }
                        )

                    case .subject:
                        if let generatedMemory {
                            CompactMemorySummary(memory: generatedMemory)
                        }

                        SouvenirSubjectQuestionPanel(
                            category: $tripoSubjectCategory,
                            detail: $tripoSubjectDetail,
                            showAdvanced: $showAdvancedSubjectOptions
                        )

                        VStack(spacing: 10) {
                            Toggle(isOn: $notifyWhenModelReady) {
                                Text("生成完成时提醒我")
                                    .font(.subheadline)
                            }
                            .tint(Color.trouvenirTeal)

                            Button {
                                Task {
                                    await generateTripoSouvenir()
                                }
                            } label: {
                                Label("开始生成 3D 纪念品", systemImage: "cube.transparent")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.trouvenirInk)
                            .disabled(isGenerating3D || normalizedTripoSubject.isEmpty)

                            Button("返回修改旅行描述") {
                                withAnimation(.snappy) {
                                    creationStage = .memory
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                            Button("新建旅行") {
                                startNewTravel()
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.trouvenirTeal)
                        }

                    case .model:
                        TripoModelPanel(
                            task: tripoTask,
                            errorMessage: tripoError,
                            memoryGenerated: generatedMemory != nil,
                            hasSubject: !normalizedTripoSubject.isEmpty,
                            isGenerating: isGenerating3D,
                            openModel: { url in
                                let proxiedURL = tripoClient.proxiedModelURL(for: url)
                                ModelRenderDiagnostics.shared.recordModelOpen(
                                    source: "memory_studio",
                                    modelURL: url,
                                    proxiedURL: proxiedURL
                                )
                                modelViewerURL = proxiedURL
                            },
                            action: {
                                Task {
                                    await generateTripoSouvenir()
                                }
                            }
                        )

                        Button {
                            startNewTravel()
                        } label: {
                            Label("新建旅行", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.trouvenirTeal)

                        GenerationArchiveSummary(
                            memory: generatedMemory,
                            task: tripoTask,
                            openCollection: openCollection
                        )
                    }
                }
                .padding(20)
            }
            .background(Color.trouvenirCanvas)
            .navigationTitle("Trouvenir")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(
            isPresented: Binding(
                get: { modelViewerURL != nil },
                set: { isPresented in
                    if !isPresented {
                        modelViewerURL = nil
                    }
                }
            )
        ) {
            if let modelViewerURL {
                ModelViewerSheet(modelURL: modelViewerURL)
            }
        }
        .alert("生成完成", isPresented: Binding(
            get: { completionMessage != nil },
            set: { isPresented in
                if !isPresented {
                    completionMessage = nil
                }
            }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(completionMessage ?? "")
        }
    }

    @MainActor
    private func generateMemory() async {
        guard !isGeneratingMemory else { return }

        isGeneratingMemory = true
        memoryError = nil
        tripoTask = nil
        tripoError = nil
        tripoSubjectCategory = "人物"
        tripoSubjectDetail = ""
        progress = 0.08
        currentStep = "读取旅行线索"

        let steps: [(String, Double)] = [
            ("发送给 AI 分析目的地和人物", 0.24),
            ("提炼这次旅行的情绪峰值", 0.46),
            ("生成旅行身份卡和故事", 0.72),
            ("准备旅行纪念品预览", 1.0)
        ]

        do {
            try? await Task.sleep(for: .milliseconds(260))
            currentStep = steps[0].0
            withAnimation(.snappy(duration: 0.35)) {
                progress = steps[0].1
            }

            let generated = try await memoryAIClient.generateMemory(
                TravelMemoryAIRequest(
                    prompt: memoryPrompt,
                    destination: destination,
                    tripTitle: tripTitle,
                    companions: companions,
                    feeling: feeling,
                    photoCount: selectedItems.count
                )
            )

            for step in steps.dropFirst() {
                try? await Task.sleep(for: .milliseconds(260))
                currentStep = step.0
                withAnimation(.snappy(duration: 0.35)) {
                    progress = step.1
                }
            }

            let memory = generated.memoryProject(photoCount: max(selectedItems.count, 6))
            generatedMemory = memory
            memories.append(memory)

            currentStep = "旅行记忆已生成，可选择继续生成 3D 纪念品"
            progress = 1.0
            isGeneratingMemory = false
            withAnimation(.snappy) {
                creationStage = .subject
            }
        } catch {
            memoryError = userFacingMemoryError(error)
            currentStep = "旅行记忆生成失败"
            progress = 0.0
            isGeneratingMemory = false
        }
    }

    @MainActor
    private func generateTripoSouvenir() async {
        guard !isGenerating3D else { return }
        guard generatedMemory != nil else {
            tripoError = "请先生成旅行记忆，再生成 3D 纪念品。"
            return
        }
        guard !normalizedTripoSubject.isEmpty else {
            tripoError = "请先回答上方问题：这次 3D 只生成一个什么主体。"
            return
        }

        isGenerating3D = true
        tripoError = nil
        ModelRenderDiagnostics.shared.record(
            "tripo.generate.start",
            data: [
                "subjectCategory": tripoSubjectCategory,
                "subjectDetailLength": tripoSubjectDetail.count,
                "promptLength": tripoPrompt.count,
                "negativePromptLength": tripoNegativePrompt.count
            ]
        )
        withAnimation(.snappy) {
            creationStage = .model
        }

        do {
            let taskID: String
            if let existingTask = tripoTask, !existingTask.isFinal {
                taskID = existingTask.taskID
                ModelRenderDiagnostics.shared.record(
                    "tripo.task.resume",
                    data: [
                        "taskID": taskID,
                        "status": existingTask.status,
                        "progress": existingTask.progress ?? -1
                    ]
                )
            } else {
                tripoTask = nil
                taskID = try await tripoClient.createTextToModelTask(
                    prompt: tripoPrompt,
                    negativePrompt: tripoNegativePrompt
                )
                ModelRenderDiagnostics.shared.record(
                    "tripo.task.created",
                    data: ["taskID": taskID]
                )
            }

            let completedTask = try await pollTripoTask(taskID)
            tripoTask = completedTask
            ModelRenderDiagnostics.shared.record(
                "tripo.task.completed",
                data: [
                    "taskID": completedTask.taskID,
                    "status": completedTask.status,
                    "progress": completedTask.progress ?? -1,
                    "modelURL": completedTask.modelURL?.absoluteString ?? "",
                    "renderedImageURL": completedTask.renderedImageURL?.absoluteString ?? ""
                ]
            )
            if completedTask.status == "success" {
                attachTripoTask(completedTask)
                if notifyWhenModelReady {
                    completionMessage = "你的 3D 纪念品已经生成，可以打开模型或查看预览图。"
                }
            }
        } catch {
            tripoError = userFacingTripoError(error)
            ModelRenderDiagnostics.shared.record(
                "tripo.generate.error",
                level: "error",
                data: ["message": tripoError ?? String(describing: error)]
            )
        }

        isGenerating3D = false
    }

    @MainActor
    private func attachTripoTask(_ task: TripoTask) {
        guard let memory = generatedMemory else { return }

        let updatedMemory = memory.updated(tripoTask: task)
        generatedMemory = updatedMemory
        ModelRenderDiagnostics.shared.record(
            "tripo.task.attached",
            data: [
                "taskID": task.taskID,
                "status": task.status,
                "hasModelURL": task.modelURL != nil,
                "hasRenderedImageURL": task.renderedImageURL != nil
            ]
        )

        if let index = memories.firstIndex(where: { $0.id == memory.id }) {
            memories[index] = updatedMemory
        }
    }

    @MainActor
    private func startNewTravel() {
        withAnimation(.snappy) {
            creationStage = .memory
        }
        memoryPrompt = ""
        showAdvancedTripDetails = false
        showAdvancedSubjectOptions = false
        destination = ""
        tripTitle = ""
        companions = ""
        feeling = ""
        tripoSubjectCategory = "人物"
        tripoSubjectDetail = ""
        selectedItems = []
        generatedMemory = nil
        isGeneratingMemory = false
        isGenerating3D = false
        progress = 0.0
        currentStep = "等待上传旅行线索"
        tripoTask = nil
        tripoError = nil
        modelViewerURL = nil
        completionMessage = nil
        memoryError = nil
    }

    private func userFacingMemoryError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut:
                return "本地 AI 服务未启动，请先在 Mac 终端运行 npm run dev"
            default:
                break
            }
        }

        return error.localizedDescription
    }

    private var tripoPrompt: String {
        let safeDestination = effectiveDestination
        let destinationContext = LandmarkContext(destination: safeDestination)
        let subject = normalizedTripoSubject
        let safeTitle = promptSnippet(
            destinationContext.removingConflictingLandmarks(from: effectiveTripTitle),
            fallback: "\(safeDestination) travel memory",
            maxLength: 48
        )
        let safeFeeling = promptSnippet(
            destinationContext.removingConflictingLandmarks(from: effectiveFeeling),
            fallback: "warm, collectible, personal travel nostalgia",
            maxLength: 60
        )

        return """
        Create exactly one standalone 3D subject: \(subject). Travel context: \(safeDestination). Memory: \(safeTitle). Mood: \(safeFeeling). The output must be a single complete isolated subject only, easy to separate from background, centered, with a clean silhouette. Premium handcrafted miniature collectible, polished ceramic or enamel material, crisp details. Do not create a scene, diorama, landscape, wide base, water area, background, multiple objects, or extra characters. \(destinationContext.styleGuidance)
        """
    }

    private var normalizedTripoSubject: String {
        let category = promptSnippet(tripoSubjectCategory, fallback: "", maxLength: 28)
        let detail = promptSnippet(tripoSubjectDetail, fallback: defaultSubjectDetail(for: category), maxLength: 70)

        if category.isEmpty {
            return ""
        }

        if detail.isEmpty {
            return category
        }

        return "\(category)：\(detail)"
    }

    private func defaultSubjectDetail(for category: String) -> String {
        let memoryText = "\(effectiveTripTitle) \(effectiveFeeling)"
        switch category {
        case "人物":
            if memoryText.contains("登顶") || memoryText.contains("山顶") || memoryText.contains("爬") {
                return "拿着登山杖庆祝的旅行者"
            }
            if memoryText.contains("拍照") || memoryText.contains("相机") {
                return "拿着相机记录风景的旅行者"
            }
            return "带着旅行背包回头看风景的人"
        case "地标":
            return "一个完整、易隔离的地标局部"
        case "交通工具":
            return "一个小型旅行交通工具"
        case "随身物件":
            return "一个有旅行纪念感的随身物件"
        case "美食":
            return "一份完整、精致、易隔离的当地美食"
        default:
            return ""
        }
    }

    private var tripoNegativePrompt: String {
        let safeDestination = effectiveDestination
        let destinationContext = LandmarkContext(destination: safeDestination)
        return promptSnippet(
            "\(destinationContext.negativePrompt), multiple subjects, multiple characters, full scene, diorama, environment, background, props surrounding the subject",
            fallback: "multiple subjects, wide landscape, flat scenic base",
            maxLength: 220
        )
    }

    private func userFacingTripoError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut:
                return "本地生成服务未启动，请先在 Mac 终端运行 npm run dev"
            default:
                break
            }
        }

        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("network request failed")
            || message.localizedCaseInsensitiveContains("connection reset")
            || message.localizedCaseInsensitiveContains("recv failure")
            || message.localizedCaseInsensitiveContains("timed out") {
            return "生成服务网络短暂中断，任务已保留。请稍后点“继续检查 3D 任务”。"
        }

        if message.localizedCaseInsensitiveContains("not enough credit")
            || message.localizedCaseInsensitiveContains("2010") {
            return "Tripo OpenAPI 钱包余额不足。Studio 里的会员 credits 和 API credits 不共享，请在 API Billing 页充值后再生成。"
        }

        return message
    }

    private var effectiveDestination: String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        let text = memoryPrompt
        if text.contains("富士山") || text.contains("河口湖") {
            return "富士山"
        }
        if text.contains("旧金山") || text.contains("金门") || text.localizedCaseInsensitiveContains("san francisco") {
            return "旧金山"
        }
        if text.localizedCaseInsensitiveContains("alcatraz") || text.contains("恶魔岛") {
            return "旧金山"
        }
        if text.localizedCaseInsensitiveContains("newport beach") || text.contains("纽波特海滩") {
            return "Newport Beach"
        }
        if text.contains("洛杉矶")
            || text.contains("洛杉磯")
            || text.contains("好莱坞")
            || text.contains("好萊塢")
            || text.localizedCaseInsensitiveContains("los angeles")
            || text.localizedCaseInsensitiveContains("hollywood") {
            return "洛杉矶"
        }
        if text.contains("东京") {
            return "东京"
        }
        if text.localizedCaseInsensitiveContains("hamilton") {
            return "Hamilton Island"
        }
        return "新的目的地"
    }

    private var effectiveTripTitle: String {
        let trimmed = tripTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        let fallback = memoryPrompt
            .components(separatedBy: CharacterSet(charactersIn: "。！？\n"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if fallback.isEmpty {
            return "一段新的旅行记忆"
        }
        return String(fallback.prefix(18))
    }

    private var effectiveFeeling: String {
        let trimmed = feeling.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        let prompt = memoryPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            return prompt
        }

        return "你站在那里，知道这趟旅行已经变成了人生里会被反复想起的一页。"
    }

    private var effectiveCompanions: String {
        let trimmed = companions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        if memoryPrompt.contains("弟弟") {
            return "弟弟"
        }
        if memoryPrompt.contains("朋友") {
            return "朋友"
        }
        if memoryPrompt.contains("家人") {
            return "家人"
        }
        return "独自旅行"
    }

    private func promptSnippet(_ text: String, fallback: String, maxLength: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return fallback
        }

        if trimmed.count <= maxLength {
            return trimmed
        }

        return String(trimmed.prefix(maxLength))
    }

    private func souvenirActionConcept(destinationContext: LandmarkContext, title: String) -> String {
        let combinedText = "\(destinationContext.destination) \(title)"

        switch destinationContext.kind {
        case .mountFuji:
            if combinedText.contains("登顶") || combinedText.contains("山顶") {
                return "Small climber cheers with trekking pole beside elegant miniature Mount Fuji"
            }
            return "Traveler with camera beside elegant blue-white miniature Mount Fuji"
        case .sanFrancisco:
            return "Tiny traveler with camera beside red-orange Golden Gate Bridge tower, curved cables, bay fog, cable car charm"
        case .generic:
            break
        }

        if combinedText.contains("极光") {
            return "A traveler in a winter jacket opens both arms under a small aurora ribbon motif"
        }

        if combinedText.contains("跳伞") {
            return "A joyful skydiver lands with a compact folded parachute attached"
        }

        if combinedText.contains("热气球") {
            return "A traveler waves from a small stylized hot air balloon basket"
        }

        return "A traveler makes a memorable celebratory pose at the peak emotional moment"
    }

    @MainActor
    private func pollTripoTask(_ taskID: String) async throws -> TripoTask {
        var lastTask = TripoTask.placeholder(taskID: taskID)
        var lastLoggedProgress = -1
        var consecutiveFailures = 0
        if let currentTask = tripoTask, currentTask.taskID == taskID {
            lastTask = currentTask
            lastLoggedProgress = currentTask.progress ?? -1
        } else {
            tripoTask = lastTask
        }

        for pollIndex in 0..<180 {
            do {
                let task = try await tripoClient.fetchTask(taskID: taskID)
                consecutiveFailures = 0
                lastTask = task
                tripoTask = task
                let currentProgress = task.progress ?? -1
                if task.isFinal || abs(currentProgress - lastLoggedProgress) >= 10 {
                    ModelRenderDiagnostics.shared.record(
                        "tripo.task.poll",
                        data: [
                            "taskID": task.taskID,
                            "status": task.status,
                            "progress": currentProgress,
                            "pollIndex": pollIndex
                        ]
                    )
                    lastLoggedProgress = currentProgress
                }

                if task.isFinal {
                    return task
                }

                try await Task.sleep(for: .seconds(3))
            } catch {
                consecutiveFailures += 1
                let retryDelaySeconds = min(18, max(3, consecutiveFailures * 3))
                ModelRenderDiagnostics.shared.record(
                    "tripo.task.poll.error",
                    level: consecutiveFailures >= 8 ? "error" : "warn",
                    data: [
                        "taskID": taskID,
                        "pollIndex": pollIndex,
                        "consecutiveFailures": consecutiveFailures,
                        "retryDelaySeconds": retryDelaySeconds,
                        "message": userFacingTripoError(error)
                    ]
                )

                if consecutiveFailures >= 8 {
                    throw error
                }

                try await Task.sleep(for: .seconds(retryDelaySeconds))
            }
        }

        ModelRenderDiagnostics.shared.record(
            "tripo.task.poll.timeout",
            level: "error",
            data: [
                "taskID": taskID,
                "status": lastTask.status,
                "progress": lastTask.progress ?? -1
            ]
        )
        throw TripoAPIError.server("3D 任务仍在生成，请稍后点击继续检查任务状态。")
    }
}

struct HeroHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("把旅行变成可以收藏的人生纪念品")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color.trouvenirInk)
                .fixedSize(horizontal: false, vertical: true)

            Text("一句话开始，逐步生成旅行记忆和 3D 纪念品。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }
}

struct CreationStepHeader: View {
    let stage: CreationStage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(CreationStage.allCases, id: \.self) { item in
                    VStack(spacing: 6) {
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(item.rawValue <= stage.rawValue ? Color.trouvenirInk : Color.secondary)

                        Capsule()
                            .fill(item.rawValue <= stage.rawValue ? Color.trouvenirTeal.opacity(0.72) : Color.black.opacity(0.08))
                            .frame(height: 4)
                    }
                }
            }

            Text(stage.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct MetricPill: View {
    let value: String
    let label: String
    var systemImage: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.trouvenirTeal)
            }
            Text(value)
                .font(.headline.weight(.bold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }
}

struct LabeledTextField: View {
    let title: String
    @Binding var text: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(title, text: $text)
                .textInputAutocapitalization(.never)
                .padding(13)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct PhotoImportStrip: View {
    @Binding var selectedItems: [PhotosPickerItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("旅行照片", systemImage: "photo.on.rectangle.angled")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                PhotosPicker(selection: $selectedItems, maxSelectionCount: 12, matching: .images) {
                    Label("添加", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(0..<max(selectedItems.count, 5), id: \.self) { index in
                        PhotoSlot(index: index, isFilled: index < selectedItems.count)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct PhotoSlot: View {
    let index: Int
    let isFilled: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(isFilled ? Color.trouvenirTeal.opacity(0.18) : Color(.secondarySystemBackground))

            Image(systemName: isFilled ? "checkmark.seal.fill" : "photo")
                .font(.title2)
                .foregroundStyle(isFilled ? Color.trouvenirTeal : Color.secondary)

            Text("\(index + 1)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: 72, height: 86)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }
}

struct MemoryPromptStep: View {
    @Binding var prompt: String
    @Binding var destination: String
    @Binding var tripTitle: String
    @Binding var companions: String
    @Binding var feeling: String
    @Binding var selectedItems: [PhotosPickerItem]
    @Binding var showAdvanced: Bool
    let isGenerating: Bool
    let progress: Double
    let currentStep: String
    let errorMessage: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("先讲这次旅行")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.trouvenirInk)

                Text("直接输入或语音转文字，系统会自动提取目的地、人物和情绪。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .bottomTrailing) {
                PlaceholderTextEditor(
                    text: $prompt,
                    placeholder: ""
                )

                VoiceInputButton(text: $prompt)
                    .padding(12)
            }

            PhotoImportStrip(selectedItems: $selectedItems)

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledTextField(title: "目的地", text: $destination, icon: "mappin.and.ellipse")
                    LabeledTextField(title: "核心记忆", text: $tripTitle, icon: "heart.text.square")
                    LabeledTextField(title: "同行的人", text: $companions, icon: "person.2")
                    LabeledTextField(title: "当时的感受", text: $feeling, icon: "quote.bubble")
                }
                .padding(.top, 8)
            } label: {
                Label("高级选项", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.trouvenirInk)
            }

            if isGenerating {
                VStack(alignment: .leading, spacing: 8) {
                    Text(currentStep)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress)
                        .tint(Color.trouvenirTeal)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.trouvenirCoral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: action) {
                Label(isGenerating ? "正在生成旅行记忆" : "下一步", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.trouvenirInk)
            .disabled(isGenerating)
        }
        .padding(16)
        .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }
}

struct PlaceholderTextEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .frame(minHeight: 132)
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.secondary.opacity(0.72))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct VoiceInputButton: View {
    @Binding var text: String
    @StateObject private var speechInput = SpeechInputController()
    @State private var baseText = ""

    var body: some View {
        Button {
            if speechInput.isRecording {
                speechInput.stopRecording()
            } else {
                baseText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                speechInput.startRecording()
            }
        } label: {
            Label(speechInput.isRecording ? "停止" : "语音输入", systemImage: speechInput.isRecording ? "stop.fill" : "mic.fill")
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    speechInput.isRecording ? Color.trouvenirCoral.opacity(0.18) : Color.white.opacity(0.9),
                    in: Capsule()
                )
                .foregroundStyle(speechInput.isRecording ? Color.trouvenirCoral : Color.trouvenirTeal)
                .overlay(
                    Capsule()
                        .stroke((speechInput.isRecording ? Color.trouvenirCoral : Color.trouvenirTeal).opacity(0.22))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speechInput.isRecording ? "停止语音输入" : "开始语音输入")
        .onChange(of: speechInput.transcript) { _, transcript in
            let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedTranscript.isEmpty else { return }

            if baseText.isEmpty {
                text = cleanedTranscript
            } else {
                text = "\(baseText)\n\(cleanedTranscript)"
            }
        }
        .alert("语音输入不可用", isPresented: Binding(
            get: { speechInput.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    speechInput.errorMessage = nil
                }
            }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(speechInput.errorMessage ?? "")
        }
    }
}

@MainActor
final class SpeechInputController: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func startRecording() {
        Task {
            let permission = await Self.requestSpeechAndMicPermission()
            guard permission.isAllowed else {
                errorMessage = permission.message
                return
            }

            do {
                try beginRecording()
            } catch {
                stopRecording()
                errorMessage = "无法启动语音输入，请检查麦克风权限或稍后重试。"
            }
        }
    }

    func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func beginRecording() throws {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "当前设备暂时无法使用中文语音识别。"
            return
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        transcript = ""

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.stopRecording()
                    }
                }

                if error != nil {
                    self.stopRecording()
                    self.errorMessage = "语音识别中断了，请再试一次。"
                }
            }
        }
    }

    nonisolated private static func requestSpeechAndMicPermission() async -> SpeechPermissionResult {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard speechStatus == .authorized else {
            return SpeechPermissionResult(isAllowed: false, message: "请在系统设置中允许 Trouvenir 使用语音识别。")
        }

        let micAllowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }

        guard micAllowed else {
            return SpeechPermissionResult(isAllowed: false, message: "请在系统设置中允许 Trouvenir 使用麦克风。")
        }

        return SpeechPermissionResult(isAllowed: true, message: "")
    }
}

struct SpeechPermissionResult {
    let isAllowed: Bool
    let message: String
}

struct CompactMemorySummary: View {
    let memory: MemoryProject

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("旅行记忆已生成")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.trouvenirInk)

            HStack(spacing: 10) {
                Label(memory.destination, systemImage: "mappin.and.ellipse")
                Label(memory.companions, systemImage: "person.2")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(memory.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.trouvenirInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }
}

struct SouvenirSubjectQuestionPanel: View {
    @Binding var category: String
    @Binding var detail: String
    @Binding var showAdvanced: Bool

    private let question = askUserQuestion()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble")
                    .font(.title3)
                    .foregroundStyle(Color.trouvenirTeal)
                    .frame(width: 38, height: 38)
                    .background(Color.trouvenirTeal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(question.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.trouvenirInk)
                    Text(question.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("默认生成")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(category)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.trouvenirInk)
            }
            .padding(12)
            .background(Color.trouvenirCanvas, in: RoundedRectangle(cornerRadius: 8))

            TextField(question.detailPlaceholder(for: category), text: $detail)
                .textInputAutocapitalization(.never)
                .padding(13)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

            DisclosureGroup(isExpanded: $showAdvanced) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(question.suggestions, id: \.self) { suggestion in
                        Button {
                            category = suggestion
                        } label: {
                            Text(suggestion)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(category == suggestion ? Color.trouvenirTeal : Color.secondary)
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("修改主体类型", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Label(question.constraint, systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }
}

struct SouvenirSubjectQuestion {
    let title: String
    let subtitle: String
    let constraint: String
    let suggestions: [String]

    func detailPlaceholder(for category: String) -> String {
        switch category {
        case "人物":
            return "例如：拿着相机的背包旅行者"
        case "地标":
            return "例如：桥、灯塔、门楼、雕像"
        case "交通工具":
            return "例如：缆车、渡轮、观光巴士"
        case "随身物件":
            return "例如：相机、车票、钥匙扣、明信片"
        case "美食":
            return "例如：海鲜、烤肉、甜点、咖啡、小吃"
        default:
            return "补充这个主体的具体样子"
        }
    }
}

func askUserQuestion() -> SouvenirSubjectQuestion {
    SouvenirSubjectQuestion(
        title: "主体确认",
        subtitle: "选择这次 Tripo 要单独生成的主体类型",
        constraint: "为了稳定生成，问题只收敛主体，不让 Tripo 同时生成场景、多人、海面或复杂背景。",
        suggestions: [
            "人物",
            "地标",
            "交通工具",
            "随身物件",
            "美食"
        ]
    )
}

struct GenerationPanel: View {
    let isGenerating: Bool
    let progress: Double
    let currentStep: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "AI 生成", subtitle: currentStep)

            ProgressView(value: progress)
                .tint(.trouvenirTeal)

            Button(action: action) {
                Label(isGenerating ? "正在生成旅行记忆" : "生成旅行记忆", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(.trouvenirInk)
            .disabled(isGenerating)
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }
}

struct TripoModelPanel: View {
    let task: TripoTask?
    let errorMessage: String?
    let memoryGenerated: Bool
    let hasSubject: Bool
    let isGenerating: Bool
    let openModel: (URL) -> Void
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "3D 纪念品", subtitle: subtitle)

            if let task {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.trouvenirTeal.opacity(0.12))

                        if let renderedImageURL = task.renderedImageURL {
                            AsyncImage(url: renderedImageURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFill()
                                case .failure:
                                    Image(systemName: "cube.transparent")
                                        .font(.title)
                                        .foregroundStyle(Color.trouvenirTeal)
                                case .empty:
                                    ProgressView()
                                        .tint(.trouvenirTeal)
                                @unknown default:
                                    Image(systemName: "cube.transparent")
                                        .font(.title)
                                        .foregroundStyle(Color.trouvenirTeal)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: "cube.transparent")
                                .font(.title)
                                .foregroundStyle(Color.trouvenirTeal)
                        }
                    }
                    .frame(width: 86, height: 86)
                    .clipped()

                    VStack(alignment: .leading, spacing: 8) {
                        Label(task.localizedStatus, systemImage: task.statusIcon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.trouvenirInk)

                        ProgressView(value: Double(task.progress ?? 0), total: 100)
                            .tint(.trouvenirTeal)

                        HStack(spacing: 10) {
                            if let modelURL = task.modelURL {
                                Button {
                                    openModel(modelURL)
                                } label: {
                                    Label("打开模型", systemImage: "arrow.up.right.square")
                                        .font(.caption.weight(.semibold))
                                }
                            }

                            if let renderedImageURL = task.renderedImageURL {
                                Link(destination: renderedImageURL) {
                                    Label("预览图", systemImage: "photo")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                        }

                        if !task.isFinal || task.status != "success" {
                            tripoActionButton
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color.trouvenirCoral)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 12) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(Color.trouvenirCoral)
                        .fixedSize(horizontal: false, vertical: true)

                    tripoActionButton
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "cube.transparent")
                            .font(.title2)
                            .foregroundStyle(Color.trouvenirTeal)
                            .frame(width: 44, height: 44)
                            .background(Color.trouvenirTeal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(memoryGenerated ? "可以继续生成 3D 纪念品" : "先生成旅行记忆")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.trouvenirInk)
                            Text(hasSubject ? "这一步会调用 Tripo OpenAPI，并消耗 API credits。" : "先回答上方主体问题，避免生成复杂场景。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    tripoActionButton
                }
            }
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }

    private var tripoActionButton: some View {
        Button(action: action) {
            Label(actionTitle, systemImage: actionIcon)
                .frame(maxWidth: .infinity)
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(Color.trouvenirTeal)
        .disabled(!memoryGenerated || !hasSubject || isGenerating)
    }

    private var actionTitle: String {
        if let task, !task.isFinal {
            return isGenerating ? "正在检查 3D 任务" : "继续检查 3D 任务"
        }

        if isGenerating {
            return "正在生成 3D 纪念品"
        }

        if task?.modelURL != nil {
            return "重新生成 3D 纪念品"
        }

        return "生成 3D 纪念品"
    }

    private var actionIcon: String {
        if let task, !task.isFinal {
            return "arrow.clockwise"
        }

        return isGenerating ? "wand.and.stars" : "cube.transparent"
    }

    private var subtitle: String {
        if let task {
            if task.status == "success" {
                return "模型已返回，可以打开或保存"
            }

            return "任务 \(task.taskID)"
        }

        if errorMessage != nil {
            return "可选步骤，需要检查本地生成服务"
        }

        if !memoryGenerated {
            return "先完成上方旅行记忆生成"
        }

        return hasSubject ? "按单独主体生成，降低 Tripo 出错率" : "先回答主体问题"
    }
}

final class AppDiagnostics: @unchecked Sendable {
    static let shared = AppDiagnostics()

    private let queue = DispatchQueue(label: "com.zhuzichen.Trouvenir.app-diagnostics", qos: .utility)
    private let fileManager = FileManager.default
    private let directoryURL: URL
    private let logURL: URL
    private let bridgeURL: URL?
    private let sessionID = UUID().uuidString
    private let maxLogBytes = 512 * 1024
    private let maxLineBytes = 6 * 1024
    private let maxAge: TimeInterval = 7 * 24 * 60 * 60
    private let dedupeWindow: TimeInterval = 8
    private var lastCleanupAt = Date.distantPast
    private var recentDedupeKeys: [String: Date] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directoryURL = caches.appendingPathComponent("TrouvenirDiagnostics", isDirectory: true)
        logURL = directoryURL.appendingPathComponent("app.ndjson")
        let bridgeValue = ProcessInfo.processInfo.environment["TROUVENIR_APP_DIAGNOSTICS_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        bridgeURL = bridgeValue.flatMap(URL.init(string:))
            ?? TrouvenirAPIEnvironment.appDiagnosticsURL
    }

    var localLogPath: String {
        logURL.path
    }

    func record(
        _ event: String,
        level: String = "info",
        data: [String: Any] = [:],
        dedupeKey: String? = nil,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        let entry: [String: Any] = [
            "t": Int(Date().timeIntervalSince1970 * 1000),
            "source": "ios-app",
            "event": event,
            "level": level,
            "session": sessionID,
            "call": [
                "file": "\(file)",
                "function": "\(function)",
                "line": Int(line)
            ],
            "data": data
        ]

        let sanitized = sanitizedDictionary(entry)
        let logData = encodedLogData(sanitized)
        let bridgeData = try? JSONSerialization.data(withJSONObject: sanitized)

        queue.async { [weak self, logData, bridgeData, dedupeKey] in
            guard let self, !self.shouldSuppress(dedupeKey) else { return }
            if let logData {
                self.append(logData)
            }
            if let bridgeData {
                self.postToBridge(bridgeData)
            }
        }
    }

    func recordLocationResolution(
        _ resolution: TravelArchive.LocationResolution,
        reason: String,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        record(
            "location.resolve",
            data: [
                "reason": reason,
                "input": resolution.input,
                "normalizedKey": resolution.normalizedKey,
                "city": resolution.cityName,
                "country": resolution.countryName ?? "",
                "regionCode": resolution.regionCode ?? "",
                "rule": resolution.rule,
                "matchedTerm": resolution.matchedTerm
            ],
            dedupeKey: "location.resolve:\(reason):\(resolution.normalizedKey):\(resolution.cityName):\(resolution.countryName ?? ""):\(resolution.rule)",
            file: file,
            function: function,
            line: line
        )
    }

    private func shouldSuppress(_ dedupeKey: String?) -> Bool {
        guard let dedupeKey, !dedupeKey.isEmpty else {
            return false
        }

        let now = Date()
        recentDedupeKeys = recentDedupeKeys.filter { now.timeIntervalSince($0.value) < dedupeWindow }
        if let lastSeen = recentDedupeKeys[dedupeKey],
           now.timeIntervalSince(lastSeen) < dedupeWindow {
            return true
        }

        recentDedupeKeys[dedupeKey] = now
        return false
    }

    private func append(_ data: Data) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            rotateIfNeeded()
            cleanupIfNeeded()

            if !fileManager.fileExists(atPath: logURL.path) {
                fileManager.createFile(atPath: logURL.path, contents: nil)
            }

            let handle = try FileHandle(forWritingTo: logURL)
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } catch {
            // App diagnostics must not affect the user flow.
        }
    }

    private func postToBridge(_ data: Data) {
        guard let bridgeURL else { return }
        var request = URLRequest(url: bridgeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        URLSession.shared.dataTask(with: request).resume()
    }

    private func rotateIfNeeded() {
        let attributes = try? fileManager.attributesOfItem(atPath: logURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size >= maxLogBytes else { return }

        let maxRotations = 4
        try? fileManager.removeItem(at: rotatedLogURL(maxRotations))
        for index in stride(from: maxRotations - 1, through: 1, by: -1) {
            let source = rotatedLogURL(index)
            let destination = rotatedLogURL(index + 1)
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: destination)
            }
        }
        try? fileManager.moveItem(at: logURL, to: rotatedLogURL(1))
    }

    private func cleanupIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastCleanupAt) > 60 else { return }
        lastCleanupAt = now

        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for file in files where file.lastPathComponent.hasPrefix("app.ndjson.") {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let modifiedAt = values?.contentModificationDate,
               now.timeIntervalSince(modifiedAt) > maxAge {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    private func rotatedLogURL(_ index: Int) -> URL {
        logURL.appendingPathExtension(String(index))
    }

    private func sanitizedDictionary(_ dictionary: [String: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: dictionary.map { key, value in
            (compact(key, maxLength: 80), sanitizedValue(value, key: key, depth: 0))
        })
    }

    private func encodedLogData(_ entry: [String: Any]) -> Data? {
        do {
            var writableEntry = entry
            var data = try JSONSerialization.data(withJSONObject: writableEntry)
            if data.count > maxLineBytes {
                writableEntry["data"] = ["truncated": true, "originalBytes": data.count]
                data = try JSONSerialization.data(withJSONObject: writableEntry)
            }
            data.append(contentsOf: [0x0a])
            return data
        } catch {
            return nil
        }
    }

    private func sanitizedValue(_ value: Any, key: String, depth: Int) -> Any {
        if depth > 5 {
            return "[depth-limit]"
        }

        if value is NSNull {
            return NSNull()
        }

        if key.range(of: "api[_-]?key|token|authorization|secret|password", options: .regularExpression) != nil {
            return "[redacted]"
        }

        if let url = value as? URL {
            return summarize(url: url)
        }

        if let string = value as? String {
            if key.lowercased().contains("url"),
               let url = URL(string: string),
               url.scheme != nil {
                return summarize(url: url)
            }
            return compact(string, maxLength: 700)
        }

        if let bool = value as? Bool {
            return bool
        }

        if let int = value as? Int {
            return int
        }

        if let double = value as? Double {
            return double
        }

        if let number = value as? NSNumber {
            return number
        }

        if let array = value as? [Any] {
            return array.prefix(24).map { sanitizedValue($0, key: key, depth: depth + 1) }
        }

        if let dictionary = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.prefix(40).map { item in
                (compact(item.key, maxLength: 80), sanitizedValue(item.value, key: item.key, depth: depth + 1))
            })
        }

        return compact(String(describing: value), maxLength: 220)
    }

    private func summarize(url: URL) -> [String: Any] {
        [
            "scheme": url.scheme ?? "",
            "host": url.host ?? "",
            "path": compact(url.path, maxLength: 220),
            "hasQuery": url.query != nil
        ]
    }

    private func compact(_ string: String, maxLength: Int) -> String {
        let compacted = string
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compacted.count > maxLength else {
            return compacted
        }
        return String(compacted.prefix(maxLength))
    }
}

final class ModelRenderDiagnostics: @unchecked Sendable {
    static let shared = ModelRenderDiagnostics()

    private let queue = DispatchQueue(label: "com.zhuzichen.Trouvenir.model-render-diagnostics", qos: .utility)
    private let fileManager = FileManager.default
    private let directoryURL: URL
    private let logURL: URL
    private let bridgeURL: URL?
    private let maxLogBytes = 768 * 1024
    private let maxLineBytes = 8 * 1024
    private let maxAge: TimeInterval = 7 * 24 * 60 * 60
    private var lastCleanupAt = Date.distantPast

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directoryURL = caches.appendingPathComponent("TrouvenirDiagnostics", isDirectory: true)
        logURL = directoryURL.appendingPathComponent("model-viewer.ndjson")
        let bridgeValue = ProcessInfo.processInfo.environment["TROUVENIR_RENDER_DIAGNOSTICS_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        bridgeURL = bridgeValue.flatMap(URL.init(string:))
            ?? TrouvenirAPIEnvironment.renderDiagnosticsURL
    }

    var localLogPath: String {
        logURL.path
    }

    func recordModelOpen(source: String, modelURL: URL, proxiedURL: URL) {
        record(
            "model.open.request",
            data: [
                "source": source,
                "modelURL": modelURL,
                "proxiedURL": proxiedURL
            ]
        )
    }

    func record(
        _ event: String,
        level: String = "info",
        sessionID: String? = nil,
        data: [String: Any] = [:],
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        let entry: [String: Any] = [
            "t": Int(Date().timeIntervalSince1970 * 1000),
            "event": event,
            "level": level,
            "session": sessionID ?? "",
            "call": [
                "file": "\(file)",
                "function": "\(function)",
                "line": Int(line)
            ],
            "data": data
        ]

        let sanitized = sanitizedDictionary(entry)
        let logData = encodedLogData(sanitized)
        let bridgeData = try? JSONSerialization.data(withJSONObject: sanitized)

        queue.async { [weak self, logData, bridgeData] in
            guard let self else { return }
            if let logData {
                self.append(logData)
            }
            if let bridgeData {
                self.postToBridge(bridgeData)
            }
        }
    }

    private func append(_ data: Data) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            rotateIfNeeded()
            cleanupIfNeeded()

            if !fileManager.fileExists(atPath: logURL.path) {
                fileManager.createFile(atPath: logURL.path, contents: nil)
            }

            let handle = try FileHandle(forWritingTo: logURL)
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } catch {
            // Diagnostics must never block the preview path.
        }
    }

    private func postToBridge(_ data: Data) {
        guard let bridgeURL else { return }
        var request = URLRequest(url: bridgeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        URLSession.shared.dataTask(with: request).resume()
    }

    private func rotateIfNeeded() {
        let attributes = try? fileManager.attributesOfItem(atPath: logURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size >= maxLogBytes else { return }

        let maxRotations = 4
        try? fileManager.removeItem(at: rotatedLogURL(maxRotations))
        for index in stride(from: maxRotations - 1, through: 1, by: -1) {
            let source = rotatedLogURL(index)
            let destination = rotatedLogURL(index + 1)
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: destination)
            }
        }
        try? fileManager.moveItem(at: logURL, to: rotatedLogURL(1))
    }

    private func cleanupIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastCleanupAt) > 60 else { return }
        lastCleanupAt = now

        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for file in files where file.lastPathComponent.hasPrefix("model-viewer.ndjson.") {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let modifiedAt = values?.contentModificationDate,
               now.timeIntervalSince(modifiedAt) > maxAge {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    private func rotatedLogURL(_ index: Int) -> URL {
        logURL.appendingPathExtension(String(index))
    }

    private func sanitizedDictionary(_ dictionary: [String: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: dictionary.map { key, value in
            (compact(key, maxLength: 80), sanitizedValue(value, key: key, depth: 0))
        })
    }

    private func encodedLogData(_ entry: [String: Any]) -> Data? {
        do {
            var writableEntry = entry
            var data = try JSONSerialization.data(withJSONObject: writableEntry)
            if data.count > maxLineBytes {
                writableEntry["data"] = ["truncated": true, "originalBytes": data.count]
                data = try JSONSerialization.data(withJSONObject: writableEntry)
            }
            data.append(contentsOf: [0x0a])
            return data
        } catch {
            return nil
        }
    }

    private func sanitizedValue(_ value: Any, key: String, depth: Int) -> Any {
        if depth > 5 {
            return "[depth-limit]"
        }

        if value is NSNull {
            return NSNull()
        }

        if key.range(of: "api[_-]?key|token|authorization|secret|password", options: .regularExpression) != nil {
            return "[redacted]"
        }

        if let url = value as? URL {
            return summarize(url: url)
        }

        if let string = value as? String {
            if key.lowercased().contains("url"),
               let url = URL(string: string),
               url.scheme != nil {
                return summarize(url: url)
            }
            return compact(string, maxLength: 700)
        }

        if let bool = value as? Bool {
            return bool
        }

        if let int = value as? Int {
            return int
        }

        if let double = value as? Double {
            return double
        }

        if let number = value as? NSNumber {
            return number
        }

        if let array = value as? [Any] {
            return array.prefix(24).map { sanitizedValue($0, key: key, depth: depth + 1) }
        }

        if let dictionary = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.prefix(40).map { item in
                (compact(item.key, maxLength: 80), sanitizedValue(item.value, key: item.key, depth: depth + 1))
            })
        }

        if let dictionary = value as? [AnyHashable: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.prefix(40).map { item in
                let itemKey = compact(String(describing: item.key), maxLength: 80)
                return (itemKey, sanitizedValue(item.value, key: itemKey, depth: depth + 1))
            })
        }

        return compact(String(describing: value), maxLength: 220)
    }

    private func summarize(url: URL) -> [String: Any] {
        [
            "scheme": url.scheme ?? "",
            "host": url.host ?? "",
            "path": compact(url.path, maxLength: 220),
            "hasQuery": url.query != nil,
            "length": url.absoluteString.count
        ]
    }

    private func compact(_ value: String, maxLength: Int) -> String {
        let compacted = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compacted.count > maxLength else { return compacted }
        return String(compacted.prefix(maxLength))
    }
}

struct ModelViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let modelURL: URL
    private let sessionID = UUID().uuidString

    var body: some View {
        NavigationStack {
            ModelViewerWebView(modelURL: modelURL, sessionID: sessionID)
                .navigationTitle("3D 模型预览")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") {
                            dismiss()
                        }
                    }
                }
        }
        .onAppear {
            ModelRenderDiagnostics.shared.record(
                "model.sheet.appear",
                sessionID: sessionID,
                data: ["modelURL": modelURL]
            )
        }
        .onDisappear {
            ModelRenderDiagnostics.shared.record(
                "model.sheet.disappear",
                sessionID: sessionID,
                data: ["modelURL": modelURL]
            )
        }
    }
}

struct ModelViewerWebView: UIViewRepresentable {
    let modelURL: URL
    let sessionID: String

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionID: sessionID)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController = WKUserContentController()
        configuration.userContentController.add(context.coordinator, name: "trouvenirDiagnostics")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        ModelRenderDiagnostics.shared.record(
            "model.webview.make",
            sessionID: sessionID,
            data: ["modelURL": modelURL]
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(
            modelURL: modelURL,
            in: webView,
            html: modelViewerHTML(modelURL: modelURL, sessionID: sessionID)
        )
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.record("model.webview.dismantle")
        uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "trouvenirDiagnostics")
    }

    private func modelViewerHTML(modelURL: URL, sessionID: String) -> String {
        let escapedURL = modelURL.absoluteString.htmlEscaped
        let modelURLJSON = modelURL.absoluteString.javaScriptStringLiteral
        let sessionIDJSON = sessionID.javaScriptStringLiteral
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <style>
            html, body {
              margin: 0;
              width: 100%;
              height: 100%;
              overflow: hidden;
              background: #f7f7f2;
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            }
            model-viewer {
              width: 100vw;
              height: 100vh;
              background: radial-gradient(circle at 50% 38%, #ffffff 0%, #f2f0e9 48%, #dedbd0 100%);
            }
            .status {
              position: absolute;
              left: 28px;
              right: 28px;
              top: 45%;
              transform: translateY(-50%);
              color: #1a1f21;
              text-align: center;
              line-height: 1.45;
              font-size: 15px;
            }
            .status.error { color: #d95b50; }
            .status.hidden { display: none; }
            .hint {
              position: fixed;
              left: 16px;
              right: 16px;
              bottom: max(18px, env(safe-area-inset-bottom));
              padding: 12px 14px;
              border-radius: 18px;
              background: rgba(255, 255, 255, 0.82);
              color: rgba(26, 31, 33, 0.72);
              font-size: 13px;
              text-align: center;
              backdrop-filter: blur(18px);
            }
          </style>
        </head>
        <body>
          <model-viewer
            id="viewer"
            data-src="\(escapedURL)"
            camera-controls
            auto-rotate
            shadow-intensity="0.7"
            exposure="1"
            crossorigin="anonymous">
          </model-viewer>
          <div id="status" class="status">正在加载 3D 预览组件...</div>
          <div class="hint">拖动旋转，双指缩放。若页面一直加载，请稍后重新打开或查看预览图。</div>
          <script type="module">
            const sessionID = \(sessionIDJSON);
            const modelURL = \(modelURLJSON);
            const status = document.getElementById('status');
            const viewer = document.getElementById('viewer');
            const startedAt = performance.now();
            const state = {
              assignedAt: 0,
              objectURL: null,
              loaded: false,
              lastProgress: -1,
              parseTimer: null
            };
            const post = (event, data = {}, level = 'info') => {
              try {
                window.webkit.messageHandlers.trouvenirDiagnostics.postMessage({
                  event,
                  level,
                  session: sessionID,
                  data: {
                    ...data,
                    elapsedMs: Math.round(performance.now() - startedAt)
                  }
                });
              } catch (_) {}
            };
            const setStatus = (message, isError = false) => {
              status.textContent = message;
              status.classList.toggle('error', isError);
              status.classList.remove('hidden');
              post('status.changed', { message, isError });
            };
            const eventPoint = (event) => ({
              x: Math.round(event.clientX || 0),
              y: Math.round(event.clientY || 0),
              pointerType: event.pointerType || '',
              target: event.target?.tagName || ''
            });
            const cleanupObjectURL = () => {
              if (state.objectURL) {
                URL.revokeObjectURL(state.objectURL);
                state.objectURL = null;
                post('model.objectURL.revoked');
              }
            };
            const showError = (message, error, eventName = 'model.error') => {
              post(eventName, {
                message,
                errorName: error?.name || '',
                errorMessage: error?.message || String(error || '')
              }, 'error');
              setStatus(message, true);
            };

            viewer.addEventListener('error', () => {
              showError('模型加载失败。请稍后重新打开，或先查看预览图。', null, 'model.load.error');
            });
            viewer.addEventListener('load', () => {
              state.loaded = true;
              if (state.parseTimer) {
                clearTimeout(state.parseTimer);
                state.parseTimer = null;
              }
              post('model.load.success', {
                parseDurationMs: state.assignedAt ? Math.round(performance.now() - state.assignedAt) : null
              });
              status.classList.add('hidden');
            });
            viewer.addEventListener('progress', (event) => {
              const totalProgress = Number(event.detail?.totalProgress ?? -1);
              if (totalProgress === 1 || totalProgress - state.lastProgress >= 0.1) {
                state.lastProgress = totalProgress;
                post('model.load.progress', { totalProgress });
              }
            });
            viewer.addEventListener('pointerdown', (event) => {
              post('viewer.pointerdown', eventPoint(event));
            });
            document.addEventListener('click', (event) => {
              post('document.click', eventPoint(event));
            });
            document.addEventListener('visibilitychange', () => {
              post('document.visibility', { state: document.visibilityState });
            });
            window.addEventListener('focus', () => post('window.focus'));
            window.addEventListener('blur', () => post('window.blur'));
            window.addEventListener('pagehide', () => {
              post('window.pagehide');
              cleanupObjectURL();
            });
            window.addEventListener('pageshow', () => post('window.pageshow'));
            window.addEventListener('resize', () => {
              post('window.resize', {
                width: Math.round(window.innerWidth),
                height: Math.round(window.innerHeight)
              });
            });
            window.addEventListener('error', (event) => {
              post('runtime.error', {
                message: event.message,
                filename: event.filename,
                line: event.lineno,
                column: event.colno
              }, 'error');
            });
            window.addEventListener('unhandledrejection', (event) => {
              post('runtime.unhandledRejection', {
                reason: String(event.reason?.message || event.reason || '')
              }, 'error');
            });

            const importModelViewer = async () => {
              const sources = [
                'https://unpkg.com/@google/model-viewer@4.3.1/dist/model-viewer.min.js',
                'https://cdn.jsdelivr.net/npm/@google/model-viewer@4.3.1/dist/model-viewer.min.js'
              ];
              let lastError = null;
              for (const source of sources) {
                try {
                  post('component.import.start', { source });
                  await import(source);
                  await customElements.whenDefined('model-viewer');
                  post('component.import.success', { source });
                  return;
                } catch (error) {
                  lastError = error;
                  post('component.import.failure', {
                    source,
                    message: error?.message || String(error)
                  }, 'warn');
                }
              }
              throw lastError || new Error('model-viewer import failed');
            };

            const fetchModelBlob = async () => {
              setStatus('正在下载 3D 模型...');
              const controller = new AbortController();
              const timeout = setTimeout(() => controller.abort(), 45000);
              const fetchStartedAt = performance.now();
              try {
                post('model.fetch.start', { modelURL });
                const response = await fetch(modelURL, {
                  cache: 'no-store',
                  signal: controller.signal,
                  headers: {
                    Accept: 'model/gltf-binary,application/octet-stream,*/*'
                  }
                });
                const contentLength = response.headers.get('content-length');
                const contentType = response.headers.get('content-type');
                const cacheHeader = response.headers.get('x-trouvenir-model-cache');
                if (!response.ok) {
                  throw new Error(`HTTP ${response.status}`);
                }
                const blob = await response.blob();
                if (!blob.size) {
                  throw new Error('empty model file');
                }
                const magic = await blob.slice(0, 4).text().catch(() => '');
                post('model.fetch.success', {
                  status: response.status,
                  bytes: blob.size,
                  contentLength,
                  contentType,
                  cache: cacheHeader,
                  magic,
                  durationMs: Math.round(performance.now() - fetchStartedAt)
                });
                return blob;
              } finally {
                clearTimeout(timeout);
              }
            };

            const loadModel = async () => {
              post('viewer.boot', {
                modelURL,
                userAgent: navigator.userAgent,
                devicePixelRatio: window.devicePixelRatio,
                viewport: {
                  width: Math.round(window.innerWidth),
                  height: Math.round(window.innerHeight)
                }
              });
              setStatus('正在加载 3D 预览组件...');
              await importModelViewer();
              const blob = await fetchModelBlob();
              setStatus('正在解析 3D 模型...');
              cleanupObjectURL();
              state.objectURL = URL.createObjectURL(blob);
              state.assignedAt = performance.now();
              state.loaded = false;
              viewer.src = state.objectURL;
              post('model.src.assigned', { bytes: blob.size });
              state.parseTimer = setTimeout(() => {
                if (!state.loaded) {
                  showError('3D 模型解析超时。请稍后重新打开，或先查看预览图。', null, 'model.parse.timeout');
                }
              }, 30000);
            };

            loadModel().catch((error) => {
              const isAbort = error?.name === 'AbortError';
              showError(
                isAbort ? '3D 模型下载超时。请检查本地服务后重新打开。' : '3D 模型加载失败。请稍后重新打开，或先查看预览图。',
                error,
                isAbort ? 'model.fetch.timeout' : 'viewer.boot.failure'
              );
            });
          </script>
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let sessionID: String
        private var loadedModelURL: URL?

        init(sessionID: String) {
            self.sessionID = sessionID
        }

        func load(modelURL: URL, in webView: WKWebView, html: String) {
            guard loadedModelURL != modelURL else {
                record("model.webview.reloadSkipped", data: ["modelURL": modelURL])
                return
            }

            loadedModelURL = modelURL
            record(
                "model.webview.loadHTML",
                data: [
                    "modelURL": modelURL,
                    "htmlBytes": html.utf8.count
                ]
            )
            webView.loadHTMLString(html, baseURL: TrouvenirAPIEnvironment.bridgeBaseURL)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "trouvenirDiagnostics" else { return }
            let payload = message.body as? [String: Any] ?? ["body": String(describing: message.body)]
            let event = payload["event"] as? String ?? "js.message"
            let level = payload["level"] as? String ?? "info"
            var data = payload["data"] as? [String: Any] ?? payload
            data["messageName"] = message.name
            record("js.\(event)", level: level, data: data)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            record("model.webview.navigation.start")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            record("model.webview.navigation.finish", data: ["url": webView.url?.absoluteString ?? ""])
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            record("model.webview.navigation.fail", level: "error", data: errorData(error))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            record("model.webview.navigation.provisionalFail", level: "error", data: errorData(error))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            record("model.webview.processTerminated", level: "error")
        }

        func record(_ event: String, level: String = "info", data: [String: Any] = [:]) {
            ModelRenderDiagnostics.shared.record(event, level: level, sessionID: sessionID, data: data)
        }

        private func errorData(_ error: Error) -> [String: Any] {
            let nsError = error as NSError
            return [
                "domain": nsError.domain,
                "code": nsError.code,
                "message": nsError.localizedDescription
            ]
        }
    }
}

struct GenerationArchiveSummary: View {
    let memory: MemoryProject?
    let task: TripoTask?
    let openCollection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已进入收藏馆")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.trouvenirInk)

            Text("旅行故事和纪念品会分开保存，完整内容到收藏馆里查看。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if memory != nil {
                    ArchiveSummaryPill(icon: "text.book.closed", text: "旅行故事")
                }

                if hasCompletedSouvenir {
                    ArchiveSummaryPill(icon: "cube.transparent", text: "3D 纪念品")
                }
            }

            HStack {
                Spacer()
                Button(action: openCollection) {
                    Label("查看收藏馆", systemImage: "arrow.right.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.trouvenirTeal)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.trouvenirTeal.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }

    private var hasCompletedSouvenir: Bool {
        task?.status == "success" && task?.hasVisualAsset == true
    }
}

struct ArchiveSummaryPill: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.trouvenirTeal)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.trouvenirTeal.opacity(0.10), in: Capsule())
    }
}

struct EmptyResultState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.title2)
                .foregroundStyle(Color.trouvenirTeal)
                .frame(width: 48, height: 48)
                .background(Color.trouvenirTeal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            Text("还没有生成旅行记忆")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.trouvenirInk)

            Text("填写这次旅行的目的地、核心记忆和感受后，这里会出现你的身份卡、故事和纪念品。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }
}

struct IdentityCard: View {
    let memory: MemoryProject

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(memory.destination)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(memory.identityTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                }

                Spacer()

                Image(systemName: "globe.asia.australia.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack(spacing: 10) {
                CardStat(label: "时长", value: memory.duration)
                CardStat(label: "步行", value: memory.walkingDistance)
                CardStat(label: "照片", value: "\(memory.photoCount) 张")
            }

            Label(memory.title, systemImage: "heart.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [.trouvenirInk, .trouvenirTeal, memory.accent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}

struct CardStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
            Text(value)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StoryBlock: View {
    let memory: MemoryProject

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(memory.storyTitle)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.trouvenirInk)

            Text(memory.story)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(5)

            ShareLink(item: "\(memory.storyTitle)\n\(memory.story)") {
                Label("分享故事", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }
}

struct SouvenirShelf: View {
    let items: [GeneratedSouvenir]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("纪念品灵感")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.trouvenirInk)
                Text("这些是给 3D 生成的参考方向")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(item.color.opacity(0.18))
                                .frame(width: 54, height: 54)

                            Image(systemName: item.symbol)
                                .font(.title2)
                                .foregroundStyle(item.color)
                        }

                        Text(item.name)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.trouvenirInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Text(item.caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black.opacity(0.06))
                    )
                }
            }
        }
    }
}

enum CollectionShelfTab: String, CaseIterable, Identifiable {
    case stories = "旅行故事"
    case souvenirs = "纪念品"

    var id: Self { self }

    var icon: String {
        switch self {
        case .stories:
            return "text.book.closed"
        case .souvenirs:
            return "seal"
        }
    }

    var emptyTitle: String {
        switch self {
        case .stories:
            return "还没有旅行故事"
        case .souvenirs:
            return "还没有可收藏的纪念品"
        }
    }

    var emptyMessage: String {
        switch self {
        case .stories:
            return "完成旅行记忆生成后，故事会自动归档到这里。"
        case .souvenirs:
            return "生成成功并拿到预览图或模型后，纪念品才会收进这里。"
        }
    }
}

struct CollectionView: View {
    let memories: [MemoryProject]
    @State private var selectedTab: CollectionShelfTab = .stories
    @State private var modelViewerURL: URL?
    private let tripoClient = TripoAPIClient()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CollectionShelfTabs(selectedTab: $selectedTab)

                    if memories.isEmpty {
                        EmptyCollectionState()
                    } else {
                        switch selectedTab {
                        case .stories:
                            StoryCollectionSection(memories: memories)
                        case .souvenirs:
                            SouvenirCollectionSection(memories: memories) { modelURL in
                                let proxiedURL = tripoClient.proxiedModelURL(for: modelURL)
                                ModelRenderDiagnostics.shared.recordModelOpen(
                                    source: "collection",
                                    modelURL: modelURL,
                                    proxiedURL: proxiedURL
                                )
                                modelViewerURL = proxiedURL
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.trouvenirCanvas)
            .navigationTitle("收藏馆")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(
            isPresented: Binding(
                get: { modelViewerURL != nil },
                set: { isPresented in
                    if !isPresented {
                        modelViewerURL = nil
                    }
                }
            )
        ) {
            if let modelViewerURL {
                ModelViewerSheet(modelURL: modelViewerURL)
            }
        }
        .onChange(of: selectedTab) { _, tab in
            AppDiagnostics.shared.record(
                "collection.tab.changed",
                data: ["tab": tab.rawValue]
            )
            ModelRenderDiagnostics.shared.record(
                "collection.tab.changed",
                data: ["tab": tab.rawValue]
            )
        }
    }
}

struct CollectionShelfTabs: View {
    @Binding var selectedTab: CollectionShelfTab

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(CollectionShelfTab.allCases) { tab in
                    Button {
                        withAnimation(.snappy) {
                            selectedTab = tab
                        }
                    } label: {
                        Label(tab.rawValue, systemImage: tab.icon)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(selectedTab == tab ? Color.trouvenirInk : Color.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                selectedTab == tab ? Color.trouvenirTeal.opacity(0.14) : Color.white,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color.black.opacity(selectedTab == tab ? 0 : 0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct StoryCollectionSection: View {
    let memories: [MemoryProject]

    private var storyMemories: [MemoryProject] {
        Array(memories.reversed()).deduplicatedMemories()
    }

    var body: some View {
        if storyMemories.isEmpty {
            EmptyTypedCollectionState(tab: .stories)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(storyMemories) { memory in
                    NavigationLink {
                        StoryDetailView(memory: memory)
                    } label: {
                        StoryCollectionCard(memory: memory)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct StoryCollectionCard: View {
    let memory: MemoryProject

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(memory.storyTitle)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color.trouvenirInk)
                        .lineLimit(2)
                    Text(memory.destination)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }

            Text(memory.story)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .lineLimit(3)
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }
}

struct StoryDetailView: View {
    let memory: MemoryProject

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(memory.destination)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(memory.storyTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.trouvenirInk)

                    HStack(spacing: 10) {
                        Label(memory.duration, systemImage: "calendar")
                        Label(memory.companions, systemImage: "person.2")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Text(memory.story)
                    .font(.body)
                    .foregroundStyle(Color.trouvenirInk)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)

                ShareLink(item: "\(memory.storyTitle)\n\(memory.story)") {
                    Label("分享故事", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.trouvenirTeal)
            }
            .padding(20)
        }
        .background(Color.trouvenirCanvas)
        .navigationTitle("旅行故事")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SouvenirCollectionSection: View {
    let memories: [MemoryProject]
    let openModel: (URL) -> Void

    private var souvenirMemories: [MemoryProject] {
        Array(memories.reversed())
            .filter { $0.tripoTask?.hasVisualAsset == true }
            .deduplicatedModels()
    }

    var body: some View {
        if souvenirMemories.isEmpty {
            EmptyTypedCollectionState(tab: .souvenirs)
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                ForEach(souvenirMemories) { memory in
                    if let task = memory.tripoTask {
                        NavigationLink {
                            SouvenirDetailView(memory: memory, task: task, openModel: openModel)
                        } label: {
                            SouvenirWarehouseCard(memory: memory, task: task)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct SouvenirWarehouseCard: View {
    let memory: MemoryProject
    let task: TripoTask

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SouvenirPreviewImage(task: task)
                .frame(height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(memory.title)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.trouvenirInk)
                    .lineLimit(2)

                Text(memory.destination)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }
}

struct SouvenirDetailView: View {
    let memory: MemoryProject
    let task: TripoTask
    let openModel: (URL) -> Void
    @State private var showIdeas = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SouvenirPreviewImage(task: task)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 6) {
                    Text(memory.destination)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(memory.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.trouvenirInk)
                        .fixedSize(horizontal: false, vertical: true)

                    Label(task.localizedStatus, systemImage: task.statusIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(task.status == "success" ? Color.trouvenirTeal : Color.secondary)
                }

                HStack(spacing: 12) {
                    if let modelURL = task.modelURL {
                        Button {
                            openModel(modelURL)
                        } label: {
                            Label("打开模型", systemImage: "arrow.up.right.square")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.trouvenirInk)
                    }

                    if let renderedImageURL = task.renderedImageURL {
                        Link(destination: renderedImageURL) {
                            Label("查看图片", systemImage: "photo")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.trouvenirTeal)
                    }
                }

                if !memory.souvenirs.isEmpty {
                    DisclosureGroup(isExpanded: $showIdeas) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(memory.souvenirs.prefix(4)) { item in
                                Label(item.name, systemImage: item.symbol)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.trouvenirInk)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.trouvenirCanvas, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("相关灵感 \(memory.souvenirs.count)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.trouvenirInk)
                    }
                    .padding(14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(20)
        }
        .background(Color.trouvenirCanvas)
        .navigationTitle("纪念品")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SouvenirPreviewImage: View {
    let task: TripoTask

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.trouvenirTeal.opacity(0.10))

            if let renderedImageURL = task.renderedImageURL {
                AsyncImage(url: renderedImageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        SouvenirAssetFallback()
                    case .empty:
                        ProgressView()
                            .tint(Color.trouvenirTeal)
                    @unknown default:
                        SouvenirAssetFallback()
                    }
                }
            } else {
                SouvenirAssetFallback()
            }
        }
    }
}

struct SouvenirAssetFallback: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "cube.transparent")
                .font(.largeTitle)
                .foregroundStyle(Color.trouvenirTeal)
            Text("3D 纪念品")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct EmptyTypedCollectionState: View {
    let tab: CollectionShelfTab

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: tab.icon)
                .font(.title2)
                .foregroundStyle(Color.trouvenirTeal)
                .frame(width: 48, height: 48)
                .background(Color.trouvenirTeal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            Text(tab.emptyTitle)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.trouvenirInk)

            Text(tab.emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }
}

struct EmptyCollectionState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "square.grid.2x2")
                .font(.title2)
                .foregroundStyle(Color.trouvenirTeal)
                .frame(width: 52, height: 52)
                .background(Color.trouvenirTeal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            Text("收藏馆还是空的")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.trouvenirInk)

            Text("当你完成生成后，旅行故事和可打开的纪念品资产会保存在这里。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }
}

@MainActor
final class TravelArchiveCountryResolver: ObservableObject {
    @Published private var resolvedCountryNames: [String: String] = [:]

    private var failedKeys: Set<String> = []
    private let geocoder = CLGeocoder()

    func countryName(for destination: String) -> String {
        let cityName = TravelArchive.cityName(for: destination)
        let key = TravelArchive.normalizedLocationKey(for: cityName)

        if let resolvedName = resolvedCountryNames[key] {
            return resolvedName
        }

        return TravelArchive.countryName(for: cityName)
    }

    func resolveCountries(for destinations: [String]) async {
        let cityNames = Set(destinations.map { TravelArchive.cityName(for: $0) }).sorted()

        for cityName in cityNames {
            await resolveCountry(for: cityName)
        }
    }

    private func resolveCountry(for cityName: String) async {
        let key = TravelArchive.normalizedLocationKey(for: cityName)
        guard !key.isEmpty,
              resolvedCountryNames[key] == nil,
              !failedKeys.contains(key) else {
            AppDiagnostics.shared.record(
                "location.country.resolve.skip",
                data: [
                    "city": cityName,
                    "normalizedKey": key,
                    "hasResolved": resolvedCountryNames[key] != nil,
                    "hasFailed": failedKeys.contains(key)
                ],
                dedupeKey: "country.skip:\(key)"
            )
            return
        }

        if let knownCountryName = TravelArchive.knownCountryName(for: cityName) {
            resolvedCountryNames[key] = knownCountryName
            AppDiagnostics.shared.record(
                "location.country.resolve.known",
                data: [
                    "city": cityName,
                    "normalizedKey": key,
                    "country": knownCountryName
                ],
                dedupeKey: "country.known:\(key):\(knownCountryName)"
            )
            return
        }

        do {
            AppDiagnostics.shared.record(
                "location.country.resolve.start",
                data: [
                    "city": cityName,
                    "normalizedKey": key,
                    "provider": "CLGeocoder"
                ],
                dedupeKey: "country.geocode.start:\(key)"
            )
            let placemarks = try await geocoder.geocodeAddressString(cityName)
            guard let placemark = placemarks.first else {
                failedKeys.insert(key)
                AppDiagnostics.shared.record(
                    "location.country.resolve.geocode.empty",
                    level: "warning",
                    data: [
                        "city": cityName,
                        "normalizedKey": key
                    ],
                    dedupeKey: "country.geocode.empty:\(key)"
                )
                return
            }

            let trust = TravelArchive.geocodeTrust(for: cityName, placemark: placemark)
            guard trust.isTrusted else {
                failedKeys.insert(key)
                AppDiagnostics.shared.record(
                    "location.country.resolve.geocode.rejected",
                    level: "warning",
                    data: [
                        "city": cityName,
                        "normalizedKey": key,
                        "reason": trust.reason,
                        "evidence": trust.evidence,
                        "isoCountryCode": placemark.isoCountryCode ?? "",
                        "placemarkLocality": placemark.locality ?? "",
                        "placemarkAdministrativeArea": placemark.administrativeArea ?? "",
                        "placemarkName": placemark.name ?? ""
                    ],
                    dedupeKey: "country.geocode.rejected:\(key):\(trust.reason)"
                )
                return
            }

            if let countryCode = placemark.isoCountryCode,
               let localizedName = TravelArchive.countryName(forRegionCode: countryCode) {
                resolvedCountryNames[key] = localizedName
                AppDiagnostics.shared.record(
                    "location.country.resolve.geocode.success",
                    data: [
                        "city": cityName,
                        "normalizedKey": key,
                        "country": localizedName,
                        "isoCountryCode": countryCode,
                        "placemarkLocality": placemark.locality ?? "",
                        "placemarkName": placemark.name ?? ""
                    ],
                    dedupeKey: "country.geocode.success:\(key):\(countryCode)"
                )
                return
            }

            if let countryName = placemark.country?.trimmingCharacters(in: .whitespacesAndNewlines),
               !countryName.isEmpty {
                resolvedCountryNames[key] = countryName
                AppDiagnostics.shared.record(
                    "location.country.resolve.geocode.countryName",
                    data: [
                        "city": cityName,
                        "normalizedKey": key,
                        "country": countryName,
                        "placemarkLocality": placemark.locality ?? "",
                        "placemarkName": placemark.name ?? ""
                    ],
                    dedupeKey: "country.geocode.countryName:\(key):\(countryName)"
                )
                return
            }

            failedKeys.insert(key)
            AppDiagnostics.shared.record(
                "location.country.resolve.geocode.unusable",
                level: "warning",
                data: [
                    "city": cityName,
                    "normalizedKey": key,
                    "placemarkName": placemark.name ?? ""
                ],
                dedupeKey: "country.geocode.unusable:\(key)"
            )
        } catch {
            failedKeys.insert(key)
            AppDiagnostics.shared.record(
                "location.country.resolve.geocode.error",
                level: "error",
                data: [
                    "city": cityName,
                    "normalizedKey": key,
                    "message": error.localizedDescription
                ],
                dedupeKey: "country.geocode.error:\(key):\(error.localizedDescription)"
            )
        }
    }
}

struct IdentityView: View {
    let memories: [MemoryProject]
    @StateObject private var countryResolver = TravelArchiveCountryResolver()
    @AppStorage("travelerProfileName") private var travelerName = "旅行者"
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var avatarImageData: Data?
    @State private var isEditingTravelerName = false
    @FocusState private var isTravelerNameFocused: Bool

    private var countryNames: [String] {
        Array(Set(memories.map { countryResolver.countryName(for: $0.destination) })).sorted()
    }

    private var cityCount: Int {
        Set(memories.map { TravelArchive.cityName(for: $0.destination) }).count
    }

    private var souvenirCount: Int {
        memories.reduce(0) { total, memory in
            total + memory.collectibleCount
        }
    }

    private var countryCount: Int {
        countryNames.count
    }

    private var archiveResolutionKey: String {
        memories
            .map { TravelArchive.cityName(for: $0.destination) }
            .sorted()
            .joined(separator: "|")
    }

    private var avatarFileURL: URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trouvenir/Profile", isDirectory: true)
        return directory.appendingPathComponent("traveler-avatar.jpg")
    }

    @ViewBuilder
    private var travelerNameEditor: some View {
        HStack(spacing: 8) {
            if isEditingTravelerName {
                TextField("旅行者", text: $travelerName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.trouvenirInk)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isTravelerNameFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        finishEditingTravelerName()
                    }

                Button("完成") {
                    finishEditingTravelerName()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.trouvenirTeal)
            } else {
                Text(travelerName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.trouvenirInk)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    withAnimation(.snappy) {
                        isEditingTravelerName = true
                    }
                    Task { @MainActor in
                        isTravelerNameFocused = true
                    }
                } label: {
                    Image(systemName: "pencil")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.trouvenirTeal)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("编辑旅行者名字")
            }
        }
        .padding(.vertical, 2)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionHeader(title: "旅行者档案", subtitle: "让积累感成为产品的长期价值")

                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 14) {
                            TravelerAvatarPicker(
                                avatarImageData: avatarImageData,
                                selectedAvatarItem: $selectedAvatarItem
                            )

                            VStack(alignment: .leading, spacing: 5) {
                                travelerNameEditor

                                Text(memories.isEmpty ? "新收藏家" : "旅行记忆收藏家")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onChange(of: travelerName) { _, _ in
                            limitTravelerNameLength()
                        }
                        .onChange(of: selectedAvatarItem) { _, item in
                            Task {
                                await updateAvatar(from: item)
                            }
                        }
                        .onAppear {
                            loadStoredAvatar()
                            normalizeTravelerName()
                        }

                        Divider()

                        HStack(spacing: 10) {
                            NavigationLink {
                                IdentityArchiveListView(kind: .countries, memories: memories)
                            } label: {
                                MetricPill(value: "\(countryCount)", label: "国家", systemImage: "globe.asia.australia")
                            }
                            .buttonStyle(.plain)

                            NavigationLink {
                                IdentityArchiveListView(kind: .cities, memories: memories)
                            } label: {
                                MetricPill(value: "\(cityCount)", label: "城市", systemImage: "mappin.and.ellipse")
                            }
                            .buttonStyle(.plain)

                            NavigationLink {
                                IdentityArchiveListView(kind: .memories, memories: memories)
                            } label: {
                                MetricPill(value: "\(memories.count)", label: "记忆", systemImage: "text.book.closed")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black.opacity(0.06))
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        Text("下一步成长")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Color.trouvenirInk)

                        Label(memories.isEmpty ? "生成第一段旅行记忆" : "继续生成新的旅行记忆", systemImage: "sparkles")
                        Label("已收藏 \(souvenirCount) 个旅行纪念品", systemImage: "square.grid.2x2")
                        Label(memories.isEmpty ? "完成第一张旅行身份卡" : "旅行身份卡已更新", systemImage: "lanyardcard")
                    }
                    .font(.subheadline)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black.opacity(0.06))
                    )
                }
                .padding(20)
        }
        .background(Color.trouvenirCanvas)
        .onAppear {
            AppDiagnostics.shared.record(
                "identity.appear",
                data: [
                    "memoryCount": memories.count,
                    "countryCount": countryCount,
                    "cityCount": cityCount
                ],
                dedupeKey: "identity.appear:\(memories.count):\(countryCount):\(cityCount)"
            )
        }
        .task(id: archiveResolutionKey) {
            await countryResolver.resolveCountries(for: memories.map(\.destination))
        }
    }
    }

    private func normalizeTravelerName() {
        let normalizedName = travelerName.trimmingCharacters(in: .whitespacesAndNewlines)
        travelerName = normalizedName.isEmpty ? "旅行者" : normalizedName
    }

    private func finishEditingTravelerName() {
        normalizeTravelerName()
        isTravelerNameFocused = false
        withAnimation(.snappy) {
            isEditingTravelerName = false
        }
    }

    private func limitTravelerNameLength() {
        if travelerName.count > 18 {
            travelerName = String(travelerName.prefix(18))
        }
    }

    private func loadStoredAvatar() {
        guard FileManager.default.fileExists(atPath: avatarFileURL.path),
              let data = try? Data(contentsOf: avatarFileURL) else {
            avatarImageData = nil
            return
        }
        avatarImageData = data
    }

    @MainActor
    private func updateAvatar(from item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let compressedData = image.jpegData(compressionQuality: 0.82) else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: avatarFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try compressedData.write(to: avatarFileURL, options: .atomic)
            avatarImageData = compressedData
        } catch {
            AppDiagnostics.shared.record(
                "identity.avatar.save.error",
                level: "error",
                data: ["message": error.localizedDescription]
            )
        }
    }
}

struct TravelerAvatarPicker: View {
    let avatarImageData: Data?
    @Binding var selectedAvatarItem: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
            ZStack(alignment: .bottomTrailing) {
                avatarContent
                    .frame(width: 76, height: 76)
                    .clipShape(Circle())

                Image(systemName: "camera.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.trouvenirTeal, in: Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("上传旅行者头像")
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let avatarImageData,
           let avatarImage = UIImage(data: avatarImageData) {
            Image(uiImage: avatarImage)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Circle()
                    .fill(Color.trouvenirGold.opacity(0.22))
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(Color.trouvenirGold)
            }
        }
    }
}

enum IdentityArchiveKind: String {
    case countries
    case cities
    case memories

    var title: String {
        switch self {
        case .countries:
            return "国家"
        case .cities:
            return "城市"
        case .memories:
            return "记忆"
        }
    }

    var emptyText: String {
        switch self {
        case .countries:
            return "还没有国家记录"
        case .cities:
            return "还没有城市记录"
        case .memories:
            return "还没有旅行记忆"
        }
    }
}

struct IdentityArchiveListView: View {
    let kind: IdentityArchiveKind
    let memories: [MemoryProject]
    @StateObject private var countryResolver = TravelArchiveCountryResolver()

    private var countryGroups: [(name: String, memories: [MemoryProject])] {
        Dictionary(grouping: memories) { memory in
            countryResolver.countryName(for: memory.destination)
        }
        .map { (name: $0.key, memories: $0.value) }
        .sorted { $0.name < $1.name }
    }

    private var cityGroups: [(name: String, memories: [MemoryProject])] {
        Dictionary(grouping: memories) { memory in
            TravelArchive.cityName(for: memory.destination)
        }
        .map { (name: $0.key, memories: $0.value) }
        .sorted { $0.name < $1.name }
    }

    private var archiveResolutionKey: String {
        memories
            .map { TravelArchive.cityName(for: $0.destination) }
            .sorted()
            .joined(separator: "|")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if memories.isEmpty {
                    EmptyArchiveCard(text: kind.emptyText)
                } else {
                    switch kind {
                    case .countries:
                        ForEach(countryGroups, id: \.name) { group in
                            ArchiveSummaryCard(
                                title: group.name,
                                subtitle: "\(Set(group.memories.map { TravelArchive.cityName(for: $0.destination) }).count) 个城市",
                                detail: "\(group.memories.count) 段记忆 · \(TravelArchive.collectibleCount(in: group.memories)) 件收藏",
                                icon: "globe.asia.australia"
                            )
                        }
                    case .cities:
                        ForEach(cityGroups, id: \.name) { group in
                            ArchiveSummaryCard(
                                title: group.name,
                                subtitle: countryResolver.countryName(for: group.name),
                                detail: "\(group.memories.count) 段记忆 · \(TravelArchive.collectibleCount(in: group.memories)) 件收藏",
                                icon: "mappin.and.ellipse"
                            )
                        }
                    case .memories:
                        ForEach(memories.deduplicatedMemories()) { memory in
                            NavigationLink {
                                StoryDetailView(memory: memory)
                            } label: {
                                ArchiveMemoryCard(memory: memory)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color.trouvenirCanvas)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            AppDiagnostics.shared.record(
                "identity.archive.appear",
                data: [
                    "kind": kind.rawValue,
                    "memoryCount": memories.count,
                    "countryGroups": countryGroups.map(\.name),
                    "cityGroups": cityGroups.map(\.name)
                ],
                dedupeKey: "identity.archive.appear:\(kind.rawValue):\(archiveResolutionKey)"
            )
        }
        .task(id: archiveResolutionKey) {
            await countryResolver.resolveCountries(for: memories.map(\.destination))
        }
    }
}

struct ArchiveSummaryCard: View {
    let title: String
    let subtitle: String
    let detail: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.trouvenirTeal)
                .frame(width: 42, height: 42)
                .background(Color.trouvenirTeal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.trouvenirInk)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }
}

struct ArchiveMemoryCard: View {
    let memory: MemoryProject

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(memory.storyTitle)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color.trouvenirInk)
                        .lineLimit(2)

                    Text(memory.destination)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.trouvenirTeal)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }

            Text(memory.story)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }
}

struct EmptyArchiveCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.06))
            )
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.trouvenirInk)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MemoryProject: Identifiable {
    let id: UUID
    let title: String
    let destination: String
    let identityTitle: String
    let companions: String
    let photoCount: Int
    let walkingDistance: String
    let duration: String
    let storyTitle: String
    let story: String
    let souvenirs: [GeneratedSouvenir]
    let accent: Color
    let tripoTask: TripoTask?

    init(
        id: UUID = UUID(),
        title: String,
        destination: String,
        identityTitle: String,
        companions: String,
        photoCount: Int,
        walkingDistance: String,
        duration: String,
        storyTitle: String,
        story: String,
        souvenirs: [GeneratedSouvenir],
        accent: Color,
        tripoTask: TripoTask? = nil
    ) {
        self.id = id
        self.title = title
        self.destination = destination
        self.identityTitle = identityTitle
        self.companions = companions
        self.photoCount = photoCount
        self.walkingDistance = walkingDistance
        self.duration = duration
        self.storyTitle = storyTitle
        self.story = story
        self.souvenirs = souvenirs
        self.accent = accent
        self.tripoTask = tripoTask
    }

    var collectibleCount: Int {
        tripoTask?.hasVisualAsset == true ? 1 : 0
    }

    var collectionSimilarityText: String {
        "\(destination) \(title) \(storyTitle) \(story)"
    }

    var modelSimilarityText: String {
        let modelURL = tripoTask?.modelURL?.absoluteString ?? ""
        let renderedImageURL = tripoTask?.renderedImageURL?.absoluteString ?? ""
        return "\(destination) \(title) \(modelURL) \(renderedImageURL)"
    }

    func updated(tripoTask: TripoTask) -> MemoryProject {
        MemoryProject(
            id: id,
            title: title,
            destination: destination,
            identityTitle: identityTitle,
            companions: companions,
            photoCount: photoCount,
            walkingDistance: walkingDistance,
            duration: duration,
            storyTitle: storyTitle,
            story: story,
            souvenirs: souvenirs,
            accent: accent,
            tripoTask: tripoTask
        )
    }

    func isSimilarCollectionItem(to other: MemoryProject) -> Bool {
        TextSimilarity.isSimilar(collectionSimilarityText, other.collectionSimilarityText)
    }

    func isSimilarModelItem(to other: MemoryProject) -> Bool {
        if let modelURL = tripoTask?.modelURL,
           let otherModelURL = other.tripoTask?.modelURL,
           modelURL == otherModelURL {
            return true
        }

        if let imageURL = tripoTask?.renderedImageURL,
           let otherImageURL = other.tripoTask?.renderedImageURL,
           imageURL == otherImageURL {
            return true
        }

        return TextSimilarity.isSimilar(modelSimilarityText, other.modelSimilarityText)
    }
}

extension Array where Element == MemoryProject {
    func deduplicatedMemories() -> [MemoryProject] {
        deduplicated { current, accepted in
            current.isSimilarCollectionItem(to: accepted)
        }
    }

    func deduplicatedModels() -> [MemoryProject] {
        deduplicated { current, accepted in
            current.isSimilarModelItem(to: accepted)
        }
    }

    private func deduplicated(_ isDuplicate: (MemoryProject, MemoryProject) -> Bool) -> [MemoryProject] {
        var accepted: [MemoryProject] = []

        for memory in self {
            guard !accepted.contains(where: { isDuplicate(memory, $0) }) else {
                continue
            }
            accepted.append(memory)
        }

        return accepted
    }
}

enum TextSimilarity {
    static func isSimilar(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalized(lhs)
        let right = normalized(rhs)

        guard !left.isEmpty, !right.isEmpty else {
            return false
        }

        if left == right {
            return true
        }

        let shorterCount = min(left.count, right.count)
        let longerCount = max(left.count, right.count)
        if longerCount > 0,
           Double(shorterCount) / Double(longerCount) > 0.72,
           (left.contains(right) || right.contains(left)) {
            return true
        }

        let leftGrams = characterBigrams(left)
        let rightGrams = characterBigrams(right)
        guard !leftGrams.isEmpty, !rightGrams.isEmpty else {
            return false
        }

        let overlap = leftGrams.intersection(rightGrams).count
        let union = leftGrams.union(rightGrams).count
        return Double(overlap) / Double(union) >= 0.82
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[\\p{P}\\p{S}\\s]+", with: "", options: .regularExpression)
    }

    private static func characterBigrams(_ text: String) -> Set<String> {
        let characters = Array(text)
        guard characters.count > 1 else {
            return text.isEmpty ? [] : [text]
        }

        return Set((0..<(characters.count - 1)).map { index in
            "\(characters[index])\(characters[index + 1])"
        })
    }
}

enum StoryTitleFormatter {
    static func formatted(_ rawTitle: String, title: String, destination: String, story: String) -> String {
        let cleaned = rawTitle
            .replacingOccurrences(of: "《", with: "")
            .replacingOccurrences(of: "》", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if isWeak(cleaned, promptTitle: title) {
            return "《\(fallbackTitle(title: title, destination: destination, story: story))》"
        }

        return "《\(limited(cleaned, maxLength: 16))》"
    }

    private static func isWeak(_ title: String, promptTitle: String) -> Bool {
        guard !title.isEmpty else {
            return true
        }

        let badCharacters = CharacterSet(charactersIn: "，,。.!！?？；;、")
        return title.count > 18 ||
            title.rangeOfCharacter(from: badCharacters) != nil ||
            title.range(of: #"[0-9０-９]"#, options: .regularExpression) != nil ||
            title.contains("小时") ||
            title.contains("公里") ||
            title.contains("终于") ||
            title.hasSuffix("终") ||
            promptTitle.contains(title)
    }

    private static func fallbackTitle(title: String, destination: String, story: String) -> String {
        let combined = "\(destination) \(title) \(story)"
        if combined.contains("富士山") || combined.contains("河口湖") || combined.contains("登顶") || combined.contains("山顶") {
            return "云开见富士"
        }

        let lowercased = combined.lowercased()
        if combined.contains("旧金山") || combined.contains("金门") || lowercased.contains("golden gate") || lowercased.contains("san francisco") {
            return "雾里的金门桥"
        }

        if combined.contains("海岛") || combined.contains("海风") || combined.contains("沙滩") || lowercased.contains("island") || lowercased.contains("beach") {
            return "海风抵达时"
        }

        let place = limited(destination.trimmingCharacters(in: .whitespacesAndNewlines), maxLength: 6)
        return place.isEmpty ? "那一刻的心跳" : "\(place)的心跳"
    }

    private static func limited(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else {
            return text
        }
        return String(text.prefix(maxLength))
    }
}

enum TravelArchive {
    struct LocationResolution {
        let input: String
        let normalizedKey: String
        let cityName: String
        let countryName: String?
        let regionCode: String?
        let rule: String
        let matchedTerm: String
    }

    private struct LocationRule {
        let rule: String
        let cityName: String
        let countryName: String
        let regionCode: String
        let terms: [String]
    }

    struct GeocodeTrust {
        let isTrusted: Bool
        let reason: String
        let evidence: String
    }

    private static let locationRules: [LocationRule] = [
        LocationRule(
            rule: "known.sanFrancisco",
            cityName: "旧金山",
            countryName: "美国",
            regionCode: "US",
            terms: [
                "旧金山", "金门", "金门大桥", "san francisco", "golden gate",
                "golden gate bridge", "alcatraz", "alcatraz island", "恶魔岛"
            ]
        ),
        LocationRule(
            rule: "known.newportBeach",
            cityName: "Newport Beach",
            countryName: "美国",
            regionCode: "US",
            terms: ["newport beach", "newportbeach", "纽波特海滩"]
        ),
        LocationRule(
            rule: "known.losAngeles",
            cityName: "洛杉矶",
            countryName: "美国",
            regionCode: "US",
            terms: [
                "洛杉矶", "洛杉磯", "los angeles",
                "好莱坞", "好萊塢", "hollywood",
                "好莱坞环球影城", "好萊塢環球影城",
                "环球影城好莱坞", "環球影城好萊塢",
                "universal studios hollywood", "universal hollywood",
                "hollywood universal studios",
                "格里菲斯天文台", "griffith observatory",
                "圣莫尼卡", "聖莫尼卡", "santa monica",
                "威尼斯海滩", "威尼斯海灘", "venice beach",
                "马里布", "馬里布", "malibu"
            ]
        ),
        LocationRule(
            rule: "known.mountFuji",
            cityName: "富士山",
            countryName: "日本",
            regionCode: "JP",
            terms: ["富士山", "河口湖", "mount fuji", "fuji", "kawaguchiko"]
        ),
        LocationRule(
            rule: "known.tokyo",
            cityName: "东京",
            countryName: "日本",
            regionCode: "JP",
            terms: [
                "东京", "東京", "tokyo", "东京塔", "tokyo tower", "浅草", "asakusa",
                "银座", "ginza", "涩谷", "渋谷", "shibuya", "新宿", "shinjuku",
                "上野", "ueno", "筑地", "tsukiji", "六本木", "roppongi", "秋叶原", "akihabara"
            ]
        ),
        LocationRule(
            rule: "known.beijing",
            cityName: "北京",
            countryName: "中国大陆",
            regionCode: "CN",
            terms: ["北京", "beijing", "故宫", "紫禁城", "forbidden city", "天安门"]
        ),
        LocationRule(
            rule: "known.shanghai",
            cityName: "上海",
            countryName: "中国大陆",
            regionCode: "CN",
            terms: ["上海", "shanghai", "外滩", "bund", "陆家嘴"]
        ),
        LocationRule(
            rule: "known.huangshan",
            cityName: "黄山",
            countryName: "中国大陆",
            regionCode: "CN",
            terms: ["黄山", "huangshan"]
        ),
        LocationRule(
            rule: "known.hamiltonIsland",
            cityName: "Hamilton Island",
            countryName: "澳大利亚",
            regionCode: "AU",
            terms: ["hamilton island", "汉密尔顿岛"]
        ),
        LocationRule(
            rule: "known.paris",
            cityName: "巴黎",
            countryName: "法国",
            regionCode: "FR",
            terms: ["巴黎", "paris", "埃菲尔", "eiffel"]
        ),
        LocationRule(
            rule: "known.london",
            cityName: "伦敦",
            countryName: "英国",
            regionCode: "GB",
            terms: ["伦敦", "london", "big ben", "大本钟"]
        ),
        LocationRule(
            rule: "known.seoul",
            cityName: "首尔",
            countryName: "韩国",
            regionCode: "KR",
            terms: ["首尔", "서울", "seoul"]
        ),
        LocationRule(
            rule: "known.bangkok",
            cityName: "曼谷",
            countryName: "泰国",
            regionCode: "TH",
            terms: ["曼谷", "bangkok"]
        ),
        LocationRule(
            rule: "known.singapore",
            cityName: "新加坡",
            countryName: "新加坡",
            regionCode: "SG",
            terms: ["新加坡", "singapore"]
        ),
        LocationRule(
            rule: "known.mexicoCity",
            cityName: "墨西哥城",
            countryName: "墨西哥",
            regionCode: "MX",
            terms: ["墨西哥城", "mexico city", "ciudad de mexico", "ciudad de méxico", "cdmx"]
        )
    ]

    static func cityName(
        for destination: String,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) -> String {
        let resolution = resolveLocation(for: destination)
        AppDiagnostics.shared.recordLocationResolution(
            resolution,
            reason: "cityName",
            file: file,
            function: function,
            line: line
        )
        return resolution.cityName
    }

    static func normalizedLocationKey(for destination: String) -> String {
        normalizedLocationToken(destination)
    }

    static func countryName(
        for destination: String,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) -> String {
        let resolution = resolveLocation(for: destination)
        AppDiagnostics.shared.recordLocationResolution(
            resolution,
            reason: "countryName",
            file: file,
            function: function,
            line: line
        )

        if let countryName = resolution.countryName {
            return countryName
        }

        if let countryName = knownCountryAliasName(for: destination) {
            return countryName
        }

        let value = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未知国家" : "其他地区"
    }

    static func knownCountryName(for destination: String) -> String? {
        if let countryName = resolveLocation(for: destination).countryName {
            return countryName
        }

        return knownCountryAliasName(for: destination)
    }

    static func resolveLocation(for destination: String) -> LocationResolution {
        let value = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey = normalizedLocationToken(value)

        if let match = knownLocationRule(for: normalizedKey) {
            return LocationResolution(
                input: value,
                normalizedKey: normalizedKey,
                cityName: match.rule.cityName,
                countryName: match.rule.countryName,
                regionCode: match.rule.regionCode,
                rule: match.rule.rule,
                matchedTerm: match.term
            )
        }

        return LocationResolution(
            input: value,
            normalizedKey: normalizedKey,
            cityName: value.isEmpty ? "未知城市" : value,
            countryName: nil,
            regionCode: nil,
            rule: value.isEmpty ? "fallback.empty" : "fallback.destination",
            matchedTerm: ""
        )
    }

    static func geocodeTrust(for query: String, placemark: CLPlacemark) -> GeocodeTrust {
        let evidenceText = [
            placemark.name,
            placemark.locality,
            placemark.subLocality,
            placemark.administrativeArea,
            placemark.subAdministrativeArea,
            placemark.country,
            placemark.isoCountryCode
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let compactEvidence = evidenceText.isEmpty ? "[empty]" : evidenceText

        guard containsLatinLetter(query) else {
            let normalizedQuery = normalizedLocationToken(query)
            let normalizedEvidence = normalizedLocationToken(compactEvidence)
            if placemark.isoCountryCode?.uppercased() == "CN",
               !normalizedQuery.isEmpty,
               !normalizedEvidence.contains(normalizedQuery) {
                return GeocodeTrust(
                    isTrusted: false,
                    reason: "non-latin-cn-placemark-without-query-match",
                    evidence: compactEvidence
                )
            }
            return GeocodeTrust(isTrusted: true, reason: "non-latin-query", evidence: compactEvidence)
        }

        let coreTokens = significantLatinLocationTokens(in: query)
        guard !coreTokens.isEmpty else {
            return GeocodeTrust(isTrusted: false, reason: "generic-latin-query", evidence: compactEvidence)
        }

        let normalizedEvidence = normalizedLatinEvidence(compactEvidence)
        if let matchedToken = coreTokens.first(where: { normalizedEvidence.contains($0) }) {
            return GeocodeTrust(isTrusted: true, reason: "matched-token:\(matchedToken)", evidence: compactEvidence)
        }

        return GeocodeTrust(
            isTrusted: false,
            reason: "latin-query-without-placemark-token-match",
            evidence: compactEvidence
        )
    }

    private static func knownLocationRule(for normalizedKey: String) -> (rule: LocationRule, term: String)? {
        guard !normalizedKey.isEmpty else {
            return nil
        }

        for rule in locationRules {
            if let term = rule.terms
                .map(normalizedLocationToken)
                .first(where: { !$0.isEmpty && normalizedKey.contains($0) }) {
                return (rule, term)
            }
        }

        return nil
    }

    private static func containsLatinLetter(_ value: String) -> Bool {
        value.range(of: "[A-Za-z]", options: .regularExpression) != nil
    }

    private static func significantLatinLocationTokens(in value: String) -> [String] {
        let genericTokens: Set<String> = [
            "beach", "island", "city", "town", "county", "state", "province",
            "mount", "mountain", "lake", "river", "park", "bridge", "bay",
            "harbor", "harbour", "airport", "station", "downtown", "north",
            "south", "east", "west", "new", "old"
        ]
        return latinTokens(in: value)
            .filter { $0.count >= 4 && !genericTokens.contains($0) }
    }

    private static func normalizedLatinEvidence(_ value: String) -> String {
        latinTokens(in: value).joined(separator: " ")
    }

    private static func latinTokens(in value: String) -> [String] {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
            .filter { token in
                token.range(of: "[a-z]", options: .regularExpression) != nil
            }
    }

    private static func normalizedLocationToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "[\\p{P}\\p{S}\\s]+", with: "", options: .regularExpression)
    }

    private static func knownCountryAliasName(for destination: String) -> String? {
        let value = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }

        let normalizedKey = normalizedLocationToken(value)
        let aliases: [(name: String, terms: [String])] = [
            ("日本", ["日本", "japan"]),
            ("中国大陆", ["中国", "中国大陆", "china", "mainland china"]),
            ("美国", ["美国", "usa", "u s a", "united states", "united states of america"]),
            ("墨西哥", ["墨西哥", "mexico"]),
            ("澳大利亚", ["澳大利亚", "australia"]),
            ("法国", ["法国", "france"]),
            ("英国", ["英国", "united kingdom", "uk", "great britain"]),
            ("韩国", ["韩国", "south korea", "korea"]),
            ("泰国", ["泰国", "thailand"]),
            ("新加坡", ["新加坡", "singapore"])
        ]

        for alias in aliases {
            if alias.terms
                .map(normalizedLocationToken)
                .contains(where: { !$0.isEmpty && normalizedKey.contains($0) }) {
                return alias.name
            }
        }

        return nil
    }

    static func countryName(forRegionCode regionCode: String) -> String? {
        Locale(identifier: "zh_Hans").localizedString(forRegionCode: regionCode.uppercased())
    }

    static func collectibleCount(in memories: [MemoryProject]) -> Int {
        memories.reduce(0) { total, memory in
            total + memory.collectibleCount
        }
    }
}

struct GeneratedSouvenir: Identifiable {
    let id = UUID()
    let name: String
    let caption: String
    let symbol: String
    let color: Color
}

struct LandmarkContext {
    let destination: String
    let kind: Kind

    init(destination: String, clues: String = "") {
        self.destination = destination
        self.kind = Kind.detect(in: "\(destination) \(clues)")
    }

    var styleGuidance: String {
        switch kind {
        case .mountFuji:
            return "Mount Fuji: blue-white snow cap, clean symmetric cone, refined ridges, Japanese collector quality."
        case .sanFrancisco:
            return "San Francisco: one iconic bridge tower, graceful cables, fog ribbon, cable car charm, red-orange enamel, no full bridge deck."
        case .generic:
            return "Use a clear destination landmark motif, premium collectible silhouette, hand-painted material detail."
        }
    }

    var avoidance: String {
        switch kind {
        case .mountFuji:
            return "generic climber on a brown mountain, muddy hill, brown rock pile"
        case .sanFrancisco:
            return "Mount Fuji, snow-capped volcano, brown mountain, Japanese shrine, unrelated Asian landmark, long bridge deck, gray slab, engineering mockup, broken tower fragments"
        case .generic:
            return "unrelated famous landmarks, brown mound, muddy hill, generic mountain"
        }
    }

    var negativePrompt: String {
        "\(avoidance), unrelated landmark, wide landscape, flat scenic base, wall backdrop, water body, terrain slab"
    }

    var souvenirs: [GeneratedSouvenir] {
        let placeName = destination == "未知目的地" ? "旅途" : destination

        switch kind {
        case .mountFuji:
            return [
                GeneratedSouvenir(name: "富士山水晶球", caption: "收藏那次云层散开的瞬间", symbol: "snowflake", color: .trouvenirTeal),
                GeneratedSouvenir(name: "登顶纪念章", caption: "把山顶的欢呼变成徽章", symbol: "seal.fill", color: .trouvenirGold),
                GeneratedSouvenir(name: "旅行身份卡", caption: "属于这次旅程的身份", symbol: "lanyardcard", color: .trouvenirCoral),
                GeneratedSouvenir(name: "记忆海报", caption: "适合保存和分享", symbol: "photo.artframe", color: .trouvenirBlue)
            ]
        case .sanFrancisco:
            return [
                GeneratedSouvenir(name: "金门桥珐琅章", caption: "红橙桥塔与海湾雾带", symbol: "bridge.lane", color: .trouvenirCoral),
                GeneratedSouvenir(name: "缆车吊坠", caption: "把坡道和铃声收进掌心", symbol: "cablecar", color: .trouvenirGold),
                GeneratedSouvenir(name: "海湾雾瓶", caption: "旧金山清晨的柔雾", symbol: "cloud", color: .trouvenirTeal),
                GeneratedSouvenir(name: "旅行身份卡", caption: "属于这次城市漫游", symbol: "lanyardcard", color: .trouvenirBlue)
            ]
        case .generic:
            return [
                GeneratedSouvenir(name: "\(placeName)身份卡", caption: "属于这次旅程的身份", symbol: "lanyardcard", color: .trouvenirTeal),
                GeneratedSouvenir(name: "\(placeName)纪念章", caption: "把最重要的瞬间留下", symbol: "seal.fill", color: .trouvenirGold),
                GeneratedSouvenir(name: "\(placeName)故事卡", caption: "多年后还能重新读到", symbol: "text.book.closed", color: .trouvenirCoral),
                GeneratedSouvenir(name: "\(placeName)记忆海报", caption: "适合保存和分享", symbol: "photo.artframe", color: .trouvenirBlue)
            ]
        }
    }

    var accent: Color {
        switch kind {
        case .mountFuji:
            return .trouvenirBlue
        case .sanFrancisco:
            return .trouvenirCoral
        case .generic:
            return .trouvenirTeal
        }
    }

    func removingConflictingLandmarks(from text: String) -> String {
        guard kind == .sanFrancisco else {
            return text
        }

        let blockedTerms = ["富士山", "河口湖", "Mount Fuji", "Fuji", "snow-capped Mount Fuji"]
        var sanitized = text
        for term in blockedTerms {
            sanitized = sanitized.replacingOccurrences(of: term, with: "")
        }
        return sanitized
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum Kind: Equatable {
        case mountFuji
        case sanFrancisco
        case generic

        static func detect(in destination: String) -> Kind {
            let lowercased = destination.lowercased()
        if lowercased.contains("旧金山") ||
            lowercased.contains("san francisco") ||
            lowercased.contains("sf") ||
            lowercased.contains("golden gate") ||
            lowercased.contains("alcatraz") ||
            lowercased.contains("恶魔岛") {
            return .sanFrancisco
        }

            if lowercased.contains("富士山") ||
                lowercased.contains("河口湖") ||
                lowercased.contains("mount fuji") ||
                lowercased.contains("fuji") {
                return .mountFuji
            }

            return .generic
        }
    }
}

extension Color {
    static let trouvenirCanvas = Color(red: 0.97, green: 0.97, blue: 0.95)
    static let trouvenirInk = Color(red: 0.10, green: 0.12, blue: 0.13)
    static let trouvenirTeal = Color(red: 0.16, green: 0.46, blue: 0.44)
    static let trouvenirCoral = Color(red: 0.72, green: 0.38, blue: 0.33)
    static let trouvenirGold = Color(red: 0.70, green: 0.55, blue: 0.30)
    static let trouvenirBlue = Color(red: 0.30, green: 0.42, blue: 0.64)

    static func travelMemoryColor(for key: String) -> Color {
        switch key {
        case "coral":
            return .trouvenirCoral
        case "gold":
            return .trouvenirGold
        case "blue":
            return .trouvenirBlue
        default:
            return .trouvenirTeal
        }
    }
}

extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    var javaScriptStringLiteral: String {
        guard let data = try? JSONEncoder().encode(self),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }
}

struct TripoTask: Decodable {
    let taskID: String
    let status: String
    let progress: Int?
    let output: TripoTaskOutput?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case status
        case progress
        case output
    }

    static func placeholder(taskID: String) -> TripoTask {
        TripoTask(taskID: taskID, status: "queued", progress: 0, output: nil)
    }

    var isFinal: Bool {
        ["success", "failed", "banned", "expired", "cancelled", "unknown"].contains(status)
    }

    var modelURL: URL? {
        output?.model.flatMap(URL.init(string:))
            ?? output?.pbrModel.flatMap(URL.init(string:))
            ?? output?.baseModel.flatMap(URL.init(string:))
    }

    var renderedImageURL: URL? {
        output?.renderedImage.flatMap(URL.init(string:))
    }

    var hasVisualAsset: Bool {
        modelURL != nil || renderedImageURL != nil
    }

    var localizedStatus: String {
        switch status {
        case "queued":
            return "排队中"
        case "running":
            return "生成中"
        case "success":
            return "已完成"
        case "failed":
            return "生成失败"
        case "cancelled":
            return "已取消"
        case "expired":
            return "已过期"
        case "banned":
            return "内容未通过"
        default:
            return status
        }
    }

    var statusIcon: String {
        switch status {
        case "success":
            return "checkmark.seal.fill"
        case "failed", "cancelled", "expired", "banned":
            return "exclamationmark.triangle.fill"
        case "running":
            return "wand.and.stars"
        default:
            return "clock"
        }
    }
}

struct TripoTaskOutput: Decodable {
    let model: String?
    let baseModel: String?
    let pbrModel: String?
    let renderedImage: String?

    enum CodingKeys: String, CodingKey {
        case model
        case baseModel = "base_model"
        case pbrModel = "pbr_model"
        case renderedImage = "rendered_image"
    }
}

struct TripoTaskCreatedResponse: Decodable {
    let taskID: String

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
    }
}

struct TravelMemoryAIRequest: Encodable {
    let prompt: String
    let destination: String
    let tripTitle: String
    let companions: String
    let feeling: String
    let photoCount: Int
}

struct GeneratedTravelMemory: Decodable {
    let title: String
    let destination: String
    let identityTitle: String
    let companions: String
    let walkingDistance: String
    let duration: String
    let storyTitle: String
    let story: String
    let accentKey: String
    let souvenirs: [GeneratedTravelSouvenir]

    func memoryProject(photoCount: Int) -> MemoryProject {
        MemoryProject(
            title: title,
            destination: destination,
            identityTitle: identityTitle,
            companions: companions,
            photoCount: photoCount,
            walkingDistance: walkingDistance,
            duration: duration,
            storyTitle: StoryTitleFormatter.formatted(
                storyTitle,
                title: title,
                destination: destination,
                story: story
            ),
            story: story,
            souvenirs: souvenirs.map(\.generatedSouvenir),
            accent: Color.travelMemoryColor(for: accentKey)
        )
    }
}

struct GeneratedTravelSouvenir: Decodable {
    let name: String
    let caption: String
    let symbol: String
    let colorKey: String

    var generatedSouvenir: GeneratedSouvenir {
        GeneratedSouvenir(
            name: name,
            caption: caption,
            symbol: symbol,
            color: Color.travelMemoryColor(for: colorKey)
        )
    }
}

struct MemoryAIClient {
    private let baseURL = TrouvenirAPIEnvironment.memoryAIBaseURL

    func generateMemory(_ input: TravelMemoryAIRequest) async throws -> GeneratedTravelMemory {
        var request = URLRequest(url: baseURL.appending(path: "memory"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(input)
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MemoryAIError.invalidResponse
        }

        if !(200..<300).contains(httpResponse.statusCode) {
            let message = APIErrorResponse.message(from: data) ?? "AI 服务返回 HTTP \(httpResponse.statusCode)"
            throw MemoryAIError.server(message)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MemoryAIError.decodingFailed
        }
    }
}

enum MemoryAIError: LocalizedError {
    case invalidResponse
    case decodingFailed
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "AI 服务没有返回有效响应"
        case .decodingFailed:
            return "AI 服务返回格式无法解析"
        case .server(let message):
            return message
        }
    }
}

struct TripoAPIClient {
    private let baseURL = TrouvenirAPIEnvironment.tripoBaseURL

    func proxiedModelURL(for modelURL: URL) -> URL {
        var components = URLComponents(
            url: baseURL.appending(path: "model-proxy"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "url", value: modelURL.absoluteString)
        ]
        return components?.url ?? modelURL
    }

    func createTextToModelTask(prompt: String, negativePrompt: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "text-to-model"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": prompt,
            "negative_prompt": negativePrompt,
            "model_version": "P1-20260311",
            "texture": true,
            "pbr": true,
            "texture_quality": "standard",
            "face_limit": 20000
        ])

        let response: TripoTaskCreatedResponse = try await send(request)
        return response.taskID
    }

    func fetchTask(taskID: String) async throws -> TripoTask {
        let request = URLRequest(url: baseURL.appending(path: "tasks/\(taskID)"))
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TripoAPIError.invalidResponse
        }

        if !(200..<300).contains(httpResponse.statusCode) {
            let message = APIErrorResponse.message(from: data) ?? "生成服务返回 HTTP \(httpResponse.statusCode)"
            throw TripoAPIError.server(message)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TripoAPIError.decodingFailed
        }
    }

}

enum TripoAPIError: LocalizedError {
    case invalidResponse
    case decodingFailed
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "生成服务没有返回有效响应"
        case .decodingFailed:
            return "生成服务返回格式无法解析"
        case .server(let message):
            return message
        }
    }
}

struct APIErrorResponse: Decodable {
    let error: String?

    static func message(from data: Data) -> String? {
        try? JSONDecoder().decode(APIErrorResponse.self, from: data).error
    }
}
