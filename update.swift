import Foundation


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


// MARK: - Errors

enum UpdateError: Error {
    case fetchReleases(statusCode: Int)
    case createRelease(statusCode: Int)
    case packageDotSwift
    case noAccessToken
    case updatePackageDotSwift(Error)
    case pushChanges(Error)
}


// MARK: - Networking

func releases(from url: URL) async throws -> [Release] {
    let (data, response) = try await URLSession.shared.data(from: url)
    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
        throw UpdateError.fetchReleases(statusCode: httpResponse.statusCode)
    } else {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let releases = try decoder.decode([Release].self, from: data)
        return releases
    }
}

func createRelease(accessToken: String, url: URL, payload: ReleasePayload) async throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(payload)
    
    var request = URLRequest(url: url)
    request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("token \(accessToken)", forHTTPHeaderField: "Authorization")
    request.httpMethod = "POST"
    request.httpBody = data
    
    let (_, response) = try await URLSession.shared.data(for: request)
    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
        throw UpdateError.createRelease(statusCode: httpResponse.statusCode)
    }
}

func packageDotSwift(from url: URL) async throws -> String {
    let (data, _) = try await URLSession.shared.data(from: url)
    if let packageDotSwift = String(data: data, encoding: .utf8) {
        return packageDotSwift
    } else {
        throw UpdateError.packageDotSwift
    }
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


// MARK: - Helpers

func accessToken() throws -> String {
    guard CommandLine.arguments.count > 1 else { throw UpdateError.noAccessToken }
    return CommandLine.arguments[1]
}

func updatePackageDotSwift(with newContent: String) throws {
    let file = FileManager.default.currentDirectoryPath + "/Package.swift"
    do {
        try newContent.write(toFile: file, atomically: true, encoding: .utf8)
    } catch {
        throw UpdateError.updatePackageDotSwift(error)
    }
}

func pushChanges(release: Release) throws {
    do {
        try git("add", ".")
        try git("commit", "-m", "Bump to \(release.tagName)")
        try git("push")
    } catch {
        throw UpdateError.pushChanges(error)
    }
}


// MARK: - Execution

let executionTask = Task.detached {
    guard let intercomReleasesURL = URL(string: "https://api.github.com/repos/intercom/intercom-ios/releases"),
          let packageReleasesURL = URL(string: "https://api.github.com/repos/FelixHerrmann/intercom-ios/releases"),
          let packageDotSwiftURL = URL(string: "https://raw.githubusercontent.com/intercom/intercom-ios/master/Package.swift") else {
        exit(EXIT_FAILURE)
    }
    
    let accessToken = try accessToken()
    
    print("Checking and comparing releases ...")
    let intercomReleases = try await releases(from: intercomReleasesURL)
    let packageReleases = try await releases(from: packageReleasesURL)
    guard let intercomLatest = intercomReleases.first, let packageLatest = packageReleases.first else {
        print("One of the repositories has no releases")
        exit(EXIT_FAILURE)
    }
    guard intercomLatest.tagName != packageLatest.tagName else {
        print("Version \(packageLatest.tagName) is latest")
        exit(EXIT_SUCCESS)
    }
    
    print("Updating Package.swift ...")
    let packageDotSwift = try await packageDotSwift(from: packageDotSwiftURL)
    guard packageDotSwift != "" else {
        print("New Package.swift not available")
        exit(EXIT_FAILURE)
    }
    try updatePackageDotSwift(with: packageDotSwift)
    print("Package.swift updated successfully")
    
    print("Pushing changes to master ...")
    try pushChanges(release: intercomLatest)
    print("Changes pushed to master successfully")
    
    print("Creating release \(intercomLatest.tagName) ...")
    let payload = ReleasePayload(tagName: intercomLatest.tagName, name: intercomLatest.tagName, body: intercomLatest.body)
    try await createRelease(accessToken: accessToken, url: packageReleasesURL, payload: payload)
    print("Release \(intercomLatest.tagName) created successfully")
}

Task {
    do {
        _ = try await executionTask.value
    } catch {
        print("Error:", error)
        exit(EXIT_FAILURE)
    }
}

RunLoop.current.run()
