
import UIKit

enum ArticleFetcherError: LocalizedError {
    case doesNotExist
    case failureToGenerateURL
    case missingData
    case invalidEndpointType
    case unableToGenerateURLRequest
    case updatedContentRequestTimeout
    
    public var errorDescription: String? {
        switch self {
        case .updatedContentRequestTimeout:
            return WMFLocalizedString("article-fetcher-error-updated-content-timeout", value: "The app wasn't able to retrieve the updated content in time. Please refresh this page later to see your changes reflected.", comment: "Error shown to the user when the content doesn't update in a reasonable amount of time.")
        default:
            return CommonStrings.genericErrorDescription
        }
    }
}

@objc(WMFArticleFetcher)
final public class ArticleFetcher: Fetcher, CacheFetching {    
    @objc required public init(session: Session, configuration: Configuration) {
        #if WMF_APPS_LABS_PAGE_CONTENT_SERVICE
        super.init(session: Session.shared, configuration: Configuration.appsLabsPageContentService)
        #elseif WMF_LOCAL_PAGE_CONTENT_SERVICE
        super.init(session: Session.shared, configuration: Configuration.localPageContentService)
        #else
        super.init(session: session, configuration: configuration)
        #endif
    }
    
    public enum EndpointType: String {
        case summary
        case mediaList = "media-list"
        case mobileHtmlOfflineResources = "mobile-html-offline-resources"
        case mobileHTML = "mobile-html"
        case references = "references"
    }

    public enum MobileHTMLType: String {
        case contentAndReferences = "contentAndReferences"
        case content = "content"
        case references = "references"
        case editPreview = "editPreview"
    }

    private static let mobileHTMLOutputHeaderKey = "output-mode"
    
    struct MediaListItem {
        let imageURL: URL
        let imageTitle: String
    }
    
    @discardableResult func fetchMediaListURLs(with request: URLRequest, completion: @escaping (Result<[MediaListItem], Error>) -> Void) -> URLSessionTask? {
          return fetchMediaList(with: request) { (result, response) in
            if let statusCode = response?.statusCode,
               statusCode == 404 {
               completion(.failure(ArticleFetcherError.doesNotExist))
               return
            }
            
            struct SourceAndTitle {
                let source: MediaListItemSource
                let title: String?
            }
            
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let mediaList):
                
                var sourceAndTitles: [SourceAndTitle] = []
                for item in mediaList.items {
                    
                    guard let sources = item.sources else {
                        continue
                    }
                    
                    for source in sources {
                        sourceAndTitles.append(SourceAndTitle(source: source, title: item.title))
                    }
                }
                
                let result = sourceAndTitles.map { (sourceAndTitle) -> MediaListItem? in
                    let scheme = request.url?.scheme ?? "https"
                    let finalString = "\(scheme):\(sourceAndTitle.source.urlString)"
                    
                    guard let title = sourceAndTitle.title,
                        let url = URL(string: finalString) else {
                            return nil
                    }
                    
                    return MediaListItem(imageURL: url, imageTitle: title)
                    
                }.compactMap{ $0 }
                
                completion(.success(result))
            }
        }
    }
    
    @discardableResult func fetchOfflineResourceURLs(with request: URLRequest, completion: @escaping (Result<[URL], Error>) -> Void) -> URLSessionTask? {
        return trackedJSONDecodableTask(with: request) { (result: Result<[String]?, Error>, response) in
            if let statusCode = response?.statusCode,
                statusCode == 404 {
                completion(.failure(ArticleFetcherError.doesNotExist))
                return
            }
            
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let urlStrings):
                
                guard let urlStrings = urlStrings else {
                    completion(.failure(ArticleFetcherError.missingData))
                    return
                }
                
                let result = urlStrings.map { (urlString) -> URL? in
                    let scheme = request.url?.scheme ?? "https"
                    let finalString = "\(scheme):\(urlString)"
                    return URL(string: finalString)
                }.compactMap{ $0 }
                
                completion(.success(result))
            }
            
        }
    }
    
    @discardableResult public func fetchMediaList(with request: URLRequest, completion: @escaping (Result<MediaList, Error>, HTTPURLResponse?) -> Void) -> URLSessionTask? {
        return trackedJSONDecodableTask(with: request) { (result: Result<MediaList?, Error>, response) in
            switch result {
            case .success(let result):
                guard let mediaList = result else {
                    completion(.failure(ArticleFetcherError.missingData), response)
                    return
                }
                
                completion(.success(mediaList), response)
                
            case .failure(let error):
                completion(.failure(error), response)
            }
        }
    }
    
    public func wikitextToMobileHTMLPreviewRequest(articleURL: URL, wikitext: String, mobileHTMLOutput: MobileHTMLType = .contentAndReferences) throws -> URLRequest {
        guard
            let articleTitle = articleURL.wmf_title,
            let percentEncodedTitle = articleTitle.percentEncodedPageTitleForPathComponents,
            let url = configuration.pageContentServiceAPIURLComponentsForHost(articleURL.host, appending: ["transform", "wikitext", "to", "mobile-html", percentEncodedTitle]).url
        else {
            throw RequestError.invalidParameters
        }
        let params: [String: String] = ["wikitext": wikitext]
        let paramsJSON = try JSONEncoder().encode(params)
        var request = URLRequest(url: url)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(mobileHTMLOutput.rawValue, forHTTPHeaderField: ArticleFetcher.mobileHTMLOutputHeaderKey)
        request.httpBody = paramsJSON
        request.httpMethod = "POST"
        return request
    }
    
    public func wikitextToHTMLRequest(articleURL: URL, wikitext: String, mobileHTMLOutput: MobileHTMLType) throws -> URLRequest {
        guard
            let articleTitle = articleURL.wmf_title,
            let percentEncodedTitle = articleTitle.percentEncodedPageTitleForPathComponents
        else {
            throw RequestError.invalidParameters
        }
        
        #if WMF_LOCAL_PAGE_CONTENT_SERVICE || WMF_APPS_LABS_PAGE_CONTENT_SERVICE
        // As of April 2020, the /transform/wikitext/to/html/{article} endpoint is only available on production, not local or staging PCS.
        guard let url = Configuration.production.pageContentServiceAPIURLComponentsForHost(articleURL.host, appending: ["transform", "wikitext", "to", "html", percentEncodedTitle]).url else {
            throw RequestError.invalidParameters
        }
        #else
        guard let url = configuration.pageContentServiceAPIURLComponentsForHost(articleURL.host, appending: ["transform", "wikitext", "to", "html", percentEncodedTitle]).url else {
            throw RequestError.invalidParameters
        }
        #endif

        let params: [String: String] = ["wikitext": wikitext]
        let headers = [ArticleFetcher.mobileHTMLOutputHeaderKey: mobileHTMLOutput.rawValue]
        return session.request(with: url, method: .post, bodyParameters: params, bodyEncoding: .json, headers: headers)
    }
    
    public func htmlToMobileHTMLRequest(articleURL: URL, html: String, mobileHTMLOutput: MobileHTMLType) throws -> URLRequest {
        guard
            let articleTitle = articleURL.wmf_title,
            let percentEncodedTitle = articleTitle.percentEncodedPageTitleForPathComponents,
            let url = configuration.pageContentServiceAPIURLComponentsForHost(articleURL.host, appending: ["transform", "html", "to", "mobile-html", percentEncodedTitle]).url
        else {
            throw RequestError.invalidParameters
        }

        let headers = [ArticleFetcher.mobileHTMLOutputHeaderKey: mobileHTMLOutput.rawValue]
        return session.request(with: url, method: .post, bodyParameters: html, bodyEncoding: .html, headers: headers)
    }

    public func fetchMobileHTMLFromWikitext(articleURL: URL, wikitext: String, mobileHTMLOutput: MobileHTMLType = .contentAndReferences, completion: @escaping ((String?, URL?) -> Void)) throws {
        let mobileHtmlCompletionHandler = { (data: Data?, response: URLResponse?,  error: Error?) in
            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                completion(nil, nil)
                return
            }
            completion(html, response?.url)
        }
        let htmlRequestCompletionHandler = { (data: Data?, response: URLResponse?,  error: Error?) in
            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                completion(nil, nil)
                return
            }
            do {
                let mobileHtmlRequest = try self.htmlToMobileHTMLRequest(articleURL: articleURL, html: html, mobileHTMLOutput: mobileHTMLOutput)
                let mobileHtml = self.session.dataTask(with: mobileHtmlRequest, completionHandler: mobileHtmlCompletionHandler)
                mobileHtml?.resume()
            } catch {
                completion(nil, nil)
            }
        }
        let htmlRequest = try wikitextToHTMLRequest(articleURL: articleURL, wikitext: wikitext, mobileHTMLOutput: mobileHTMLOutput)
        let htmlTask = self.session.dataTask(with: htmlRequest, completionHandler: htmlRequestCompletionHandler)
        htmlTask?.resume()
    }
    
    public func mobileHTMLURL(articleURL: URL, revisionID: UInt64? = nil) throws -> URL {
        guard
            let articleTitle = articleURL.wmf_title,
            let percentEncodedTitle = articleTitle.percentEncodedPageTitleForPathComponents
        else {
            throw RequestError.invalidParameters
        }
        
        var pathComponents = ["page", "mobile-html", percentEncodedTitle]
        
        if let revisionID = revisionID {
            pathComponents.append("\(revisionID)")
        }
        
        guard let mobileHTMLURL = configuration.pageContentServiceAPIURLComponentsForHost(articleURL.host, appending: pathComponents).url else {
            throw RequestError.invalidParameters
        }
        
        return mobileHTMLURL
    }
    
    public func mediaListURL(articleURL: URL) throws -> URL {
        guard
            let articleTitle = articleURL.wmf_title,
            let percentEncodedTitle = articleTitle.percentEncodedPageTitleForPathComponents,
            let url = configuration.pageContentServiceAPIURLComponentsForHost(articleURL.host, appending: ["page", "media-list", percentEncodedTitle]).url
        else {
            throw RequestError.invalidParameters
        }
        
        return url
    }
    
    public func mobileHTMLMediaListRequest(articleURL: URL, cachePolicy: WMFCachePolicy? = nil) throws -> URLRequest {
        
        let url = try mediaListURL(articleURL: articleURL)
        
        if let urlRequest = urlRequest(from: url, cachePolicy: cachePolicy) {
            return urlRequest
        } else {
            throw ArticleFetcherError.unableToGenerateURLRequest
        }
    }
    
    public func mobileHTMLOfflineResourcesRequest(articleURL: URL, cachePolicy: WMFCachePolicy? = nil) throws -> URLRequest {
        guard
            let articleTitle = articleURL.wmf_title,
            let percentEncodedTitle = articleTitle.percentEncodedPageTitleForPathComponents,
            let url = configuration.pageContentServiceAPIURLComponentsForHost(articleURL.host, appending: ["page", "mobile-html-offline-resources", percentEncodedTitle]).url
        else {
            throw RequestError.invalidParameters
        }
        
        if let urlRequest = urlRequest(from: url, cachePolicy: cachePolicy) {
            return urlRequest
        } else {
            throw ArticleFetcherError.unableToGenerateURLRequest
        }
    }
    
    public func urlRequest(from url: URL, cachePolicy: WMFCachePolicy? = nil, headers: [String: String] = [:]) -> URLRequest? {
        
        let request = urlRequestFromPersistence(with: url, persistType: .article, cachePolicy: cachePolicy, headers: headers)
        
        return request
    }
    
    public func mobileHTMLRequest(articleURL: URL, revisionID: UInt64? = nil, scheme: String? = nil, cachePolicy: WMFCachePolicy? = nil, isPageView: Bool = false) throws -> URLRequest {
        
        var url = try mobileHTMLURL(articleURL: articleURL, revisionID: revisionID)
        
        if let scheme = scheme {
            var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
            urlComponents?.scheme = scheme
            url = urlComponents?.url ?? url
        }
        let acceptUTF8HTML = ["Accept": "text/html; charset=utf-8"]
        if var urlRequest = urlRequest(from: url, cachePolicy: cachePolicy, headers: acceptUTF8HTML) {
            if revisionID != nil {
                // Enables the caching system to update the revisionless url cache when this call goes through
                urlRequest.customCacheUpdatingURL = try mobileHTMLURL(articleURL: articleURL)
            }
            if isPageView {
                // https://phabricator.wikimedia.org/T256507
                urlRequest.setValue("pageview=1", forHTTPHeaderField: "X-Analytics")
            }
            return urlRequest
        } else {
            throw ArticleFetcherError.unableToGenerateURLRequest
        }
    }
    
    /// Makes periodic HEAD requests to the mobile-html endpoint until the etag no longer matches the one provided.
    @discardableResult public func waitForMobileHTMLChange(articleURL: URL, eTag: String, attempt: Int = 0, maxAttempts: Int, cancellationKey: CancellationKey? = nil, completion: @escaping (Result<String, Error>) -> Void) -> CancellationKey? {
        guard attempt < maxAttempts else {
            completion(.failure(ArticleFetcherError.updatedContentRequestTimeout))
            return nil
        }
        let requestURL: URL
        do {
            requestURL = try mobileHTMLURL(articleURL: articleURL)
        } catch let error {
            completion(.failure(error))
            return nil
        }
        let key = cancellationKey ?? UUID().uuidString
        let maybeTask = session.dataTask(with: requestURL, method: .head, headers: [URLRequest.ifNoneMatchHeaderKey: eTag], cachePolicy: .reloadIgnoringLocalCacheData) { (_, response, error) in
            defer {
                self.untrack(taskFor: key)
            }
            if let error = error {
                completion(.failure(error))
                return
            }
            let bail = {
                completion(.failure(RequestError.unexpectedResponse))
            }
            guard let httpURLResponse = response as? HTTPURLResponse else {
                bail()
                return
            }
            
            let retry = {
                // Exponential backoff
                let delayTime = 0.25 * pow(2, Double(attempt))
                dispatchOnMainQueueAfterDelayInSeconds(delayTime) {
                    self.waitForMobileHTMLChange(articleURL: articleURL, eTag: eTag, attempt: attempt + 1, maxAttempts: maxAttempts, cancellationKey: key, completion: completion)
                }
            }

            // Check for 200. The server returns 304 when the ETag matches the value we provided for `If-None-Match` above
            switch httpURLResponse.statusCode {
            case 200:
                break
            case 304:
                retry()
                return
            default:
                bail()
                return
            }
            
            guard
                let updatedETag = httpURLResponse.allHeaderFields[HTTPURLResponse.etagHeaderKey] as? String,
                updatedETag != eTag // Technically redundant. With If-None-Match provided, we should only get a 200 response if the ETag has changed. Included here as an extra check against a server behaving incorrectly
            else {
                assert(false, "A 200 response from the server should indicate that the ETag has changed")
                retry()
                return
            }
            
            DDLogDebug("ETag for \(requestURL) changed from \(eTag) to \(updatedETag)")
            completion(.success(updatedETag))
        }
        guard let task = maybeTask else {
            completion(.failure(RequestError.unknown))
            return nil
        }
        track(task: task, for: key)
        task.resume()
        return key
    }
    
    public func isCached(articleURL: URL, scheme: String? = nil, completion: @escaping (Bool) -> Void) {

        guard let request = try? mobileHTMLRequest(articleURL: articleURL, scheme: scheme) else {
            completion(false)
            return
        }
        
        return session.isCachedWithURLRequest(request, completion: completion)
    }
    
    //MARK: Bundled offline resources
    
    struct BundledOfflineResources {
        let baseCSS: URL
        let pcsCSS: URL
        let pcsJS: URL
    }
    
    let expectedNumberOfBundledOfflineResources = 3
    
    #if WMF_APPS_LABS_PAGE_CONTENT_SERVICE
     static let pcsBaseURI = "//\(Configuration.Domain.appsLabs)/api/v1/"
    #elseif WMF_LOCAL_PAGE_CONTENT_SERVICE
     static let pcsBaseURI = "//\(Configuration.Domain.localhost):8888/api/v1/"
    #else
     static let pcsBaseURI = "//\(Configuration.Domain.metaWiki)/api/rest_v1/"
    #endif
    
    func bundledOfflineResourceURLs() -> BundledOfflineResources? {
        guard
            let baseCSS = URL(string: "https:\(ArticleFetcher.pcsBaseURI)data/css/mobile/base"),
            let pcsCSS = URL(string: "https:\(ArticleFetcher.pcsBaseURI)data/css/mobile/pcs"),
            let pcsJS = URL(string: "https:\(ArticleFetcher.pcsBaseURI)data/javascript/mobile/pcs")
        else {
            return nil
        }
        return BundledOfflineResources(baseCSS: baseCSS, pcsCSS: pcsCSS, pcsJS: pcsJS)
    }
}
