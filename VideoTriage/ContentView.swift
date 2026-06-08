import SwiftUI
import Photos

struct ContentView: View {
    @StateObject private var library = VideoLibrary()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch library.authState {
            case .unknown:
                PermissionPromptView { library.requestAccess() }
            case .denied:
                DeniedView()
            case .authorized:
                if library.isLoading {
                    LoadingView()
                } else if library.assets.isEmpty {
                    EmptyView_()
                } else if library.isFinished {
                    SummaryView(library: library)
                } else {
                    TriageView(library: library)
                }
            }
        }
        .onAppear {
            // 自動で許可リクエスト（既に許可済みならそのまま読み込み）
            if library.authState == .unknown {
                library.requestAccess()
            }
        }
    }
}

// MARK: - 振り分け画面

struct TriageView: View {
    @ObservedObject var library: VideoLibrary

    var body: some View {
        VStack(spacing: 12) {
            header

            if let asset = library.current {
                SwipeCard(asset: asset) { trash in
                    library.decide(trash: trash)
                }
                .id(asset.localIdentifier)   // 次の動画になったら作り直して即再生
                .padding(.horizontal, 12)
            }

            controls
        }
        .padding(.vertical, 8)
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Label("\(library.keepCount)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Text("\(library.processed) / \(library.total)")
                    .foregroundStyle(.white.opacity(0.8))
                    .monospacedDigit()
                Spacer()
                Label("\(library.trashCount)", systemImage: "trash.circle.fill")
                    .foregroundStyle(.red)
            }
            .font(.system(size: 16, weight: .semibold))
            .padding(.horizontal, 20)

            ProgressView(value: Double(library.processed), total: Double(max(1, library.total)))
                .tint(.white)
                .padding(.horizontal, 20)
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            // いる（左）
            Button {
                library.decide(trash: false)
            } label: {
                actionButton(system: "hand.thumbsup.fill", color: .green, title: "いる")
            }

            // 戻る（Undo）
            Button {
                library.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .disabled(!library.canUndo)
            .opacity(library.canUndo ? 1 : 0.35)

            // いらない（右）
            Button {
                library.decide(trash: true)
            } label: {
                actionButton(system: "trash.fill", color: .red, title: "いらない")
            }
        }
        .padding(.top, 4)
    }

    private func actionButton(system: String, color: Color, title: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: system)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(color, in: Circle())
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - 完了 / 削除画面

struct SummaryView: View {
    @ObservedObject var library: VideoLibrary
    @State private var showConfirm = false
    @State private var resultMessage: String?

    private var isBusy: Bool { library.isFiling || library.isDeleting }
    private var hasWork: Bool { library.keepCount > 0 || library.trashCount > 0 }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("振り分け完了")
                .font(.title.bold())
                .foregroundStyle(.white)

            HStack(spacing: 36) {
                stat(count: library.keepCount, title: "いる → アルバム", color: .green)
                stat(count: library.trashCount, title: "いらない → 削除", color: .red)
            }

            if let msg = resultMessage {
                Text(msg)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    showConfirm = true
                } label: {
                    HStack {
                        if isBusy { ProgressView().tint(.white) }
                        Text(hasWork ? "実行する" : "対象がありません")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(hasWork ? Color.accentColor : Color.gray, in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!hasWork || isBusy)

                Text("いる動画は「\(VideoLibrary.keepAlbumName)」アルバムへ、いらない動画は削除します。")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)

                Button {
                    resultMessage = nil
                    library.restart()
                } label: {
                    Text("もう一度はじめから")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isBusy)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .alert("実行しますか？", isPresented: $showConfirm) {
            Button("実行", role: .destructive) { runFileThenDelete() }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("いる \(library.keepCount) 本を「\(VideoLibrary.keepAlbumName)」アルバムへ追加し、いらない \(library.trashCount) 本を削除します。\n削除時はシステムの確認も表示されます。")
        }
    }

    /// いるをアルバムへ振り分け → いらないを削除、の順で実行。
    private func runFileThenDelete() {
        let keepN = library.keepCount
        let trashN = library.trashCount
        library.fileKeepsToAlbum { filed in
            library.deleteTrash { deleted in
                let filePart = keepN == 0 ? "" :
                    (filed ? "いる \(keepN) 本を「\(VideoLibrary.keepAlbumName)」へ振り分けました。"
                           : "アルバムへの振り分けに失敗しました。")
                let deletePart = trashN == 0 ? "" :
                    (deleted ? "いらない \(trashN) 本を削除しました。"
                             : "削除がキャンセル／失敗しました。")
                resultMessage = [filePart, deletePart]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            }
        }
    }

    private func stat(count: Int, title: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(color)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

// MARK: - 補助画面

struct PermissionPromptView: View {
    let onRequest: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "film.stack")
                .font(.system(size: 60))
                .foregroundStyle(.white)
            Text("動画をスワイプで振り分け")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("右上スワイプ = いらない\n左上スワイプ = いる")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
            Button("写真へのアクセスを許可", action: onRequest)
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.horizontal, 24).frame(height: 50)
                .background(.white, in: Capsule())
                .padding(.top, 8)
        }
        .padding()
    }
}

struct DeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 50)).foregroundStyle(.white)
            Text("写真へのアクセスが必要です")
                .font(.title3.bold()).foregroundStyle(.white)
            Text("「設定」アプリ → このアプリ → 写真 で\nアクセスを許可してください。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.headline).foregroundStyle(.black)
            .padding(.horizontal, 24).frame(height: 50)
            .background(.white, in: Capsule())
        }
        .padding()
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().tint(.white).scaleEffect(1.5)
            Text("動画を読み込み中…").foregroundStyle(.white.opacity(0.8))
        }
    }
}

struct EmptyView_: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 50)).foregroundStyle(.white)
            Text("動画が見つかりませんでした").foregroundStyle(.white)
        }
    }
}
