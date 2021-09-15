import Foundation
import Combine


// MARK: - Models

struct Release: Decodable {
    let tagName: String
    let body: String
}

struct ReleasePayload: Encodable {
    let tagName: String
    let name: String
    let body: String
}


// MARK: - Publishers

func releasesPublisher(url: URL) -> AnyPublisher<[Release], Never> {
    URLSession.shared.dataTaskPublisher(for: url)
        .map(\.data)
        .decode(type: [Release].self, decoder: decoder)
        .replaceError(with: [])
        .eraseToAnyPublisher()
}

func createReleasePublisher(accessToken: String, url: URL, payload: ReleasePayload) -> Future<Void, Error> {
    return Future { promise in
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            promise(.failure(error))
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("token \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpMethod = "POST"
        request.httpBody = data
        
        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error = error {
                promise(.failure(error))
            } else {
                promise(.success(()))
            }
        }.resume()
    }
}

func packageDotSwiftPublisher(url: URL) -> AnyPublisher<String, Never> {
    URLSession.shared.dataTaskPublisher(for: url)
        .compactMap { String(data: $0.data, encoding: .utf8) }
        .replaceError(with: "")
        .eraseToAnyPublisher()
}


// MARK: - Shell

func git(_ args: String...) throws {
    let process = Process()
    let url = URL(fileURLWithPath: "/usr/bin/git")
    process.executableURL = url
    process.arguments = args
    try process.run()
    process.waitUntilExit()
}


// MARK: - Execution

guard let intercomURL = URL(string: "https://api.github.com/repos/intercom/intercom-ios/releases"),
      let packageURL = URL(string: "https://api.github.com/repos/FelixHerrmann/intercom-ios/releases"),
      let packageDotSwiftURL = URL(string: "https://raw.githubusercontent.com/intercom/intercom-ios/master/Package.swift") else {
    exit(EXIT_FAILURE)
}

guard CommandLine.arguments.count > 1 else {
    print("No access token specified")
    exit(EXIT_FAILURE)
}
let accessToken = CommandLine.arguments[1]

let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase

var cancellables: Set<AnyCancellable> = []

let a = releasesPublisher(url: intercomURL)
let b = releasesPublisher(url: packageURL)

Publishers.Zip(a, b)
    .sink { zip in
        guard let intercomLatest = zip.0.first, let packageLatest = zip.1.first else {
            print("One of the repositories has no releases")
            exit(EXIT_FAILURE)
        }
        if intercomLatest.tagName == packageLatest.tagName {
            print("Version \(packageLatest.tagName) is latest")
            exit(EXIT_SUCCESS)
        } else {
            packageDotSwiftPublisher(url: packageDotSwiftURL)
                .sink { packageDotSwift in
                    guard packageDotSwift != "" else {
                        print("New Package.swift not available")
                        exit(EXIT_FAILURE)
                    }
                    updatePackageDotSwift(with: packageDotSwift)
                    pushChanges(release: intercomLatest)
                    
                    let payload = ReleasePayload(tagName: intercomLatest.tagName, name: intercomLatest.tagName, body: intercomLatest.body)
                    createReleasePublisher(accessToken: accessToken, url: packageURL, payload: payload)
                        .sink { completion in
                            switch completion {
                            case .failure(let error):
                                print("Create release failed: ", error)
                                exit(EXIT_FAILURE)
                            case .finished:
                                print("Release \(intercomLatest.tagName) created successfully")
                                exit(EXIT_SUCCESS)
                            }
                        } receiveValue: { _ in }
                        .store(in: &cancellables)
                }
                .store(in: &cancellables)
        }
    }
    .store(in: &cancellables)

RunLoop.current.run()


func updatePackageDotSwift(with newContent: String) {
    let file = FileManager.default.currentDirectoryPath + "/Package.swift"
    do {
        try newContent.write(toFile: file, atomically: true, encoding: .utf8)
        print("Package.swift updated successfully")
    } catch {
        print("Update Package.swift file failed: ", error)
        exit(EXIT_FAILURE)
    }
}

func pushChanges(release: Release) {
    do {
        try git("add", ".")
        try git("commit", "-m", "Bump to \(release.tagName)")
        try git("push")
        print("Changes pushed to master successfully")
    } catch {
        print("Push git failed: ", error)
        exit(EXIT_FAILURE)
    }
}
