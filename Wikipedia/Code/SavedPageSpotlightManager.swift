import UIKit
import MobileCoreServices
import CoreSpotlight
import CocoaLumberjackSwift

extension URL {
    var searchableItemAttributes: CSSearchableItemAttributeSet? {
        guard wikiResourcePath != nil else {
            return nil
        }
        guard let title = self.wmf_title else {
            return nil
        }
        let components = title.components(separatedBy: " ")
        let searchableItem = CSSearchableItemAttributeSet(itemContentType: kUTTypeInternetLocation as String)
        searchableItem.keywords = ["Wikipedia","Wikimedia","Wiki"] + components
        searchableItem.title = self.wmf_title
        searchableItem.displayName = self.wmf_title
        searchableItem.identifier = NSURL.wmf_desktopURL(for: self as URL)?.absoluteString
        searchableItem.relatedUniqueIdentifier = NSURL.wmf_desktopURL(for: self as URL)?.absoluteString
        return searchableItem
    }
}

extension NSURL {
    @objc var wmf_searchableItemAttributes: CSSearchableItemAttributeSet? {
        return (self as URL).searchableItemAttributes
    }
}

public extension WMFArticle {
    var searchableItemAttributes: CSSearchableItemAttributeSet {
        let searchableItem = url?.searchableItemAttributes ??
                CSSearchableItemAttributeSet(itemContentType: kUTTypeInternetLocation as String)

        searchableItem.subject = wikidataDescription
        searchableItem.contentDescription = snippet
        if let imageURL = imageURL(forWidth: WMFImageWidth.medium.rawValue) {
            searchableItem.thumbnailData = ImageCacheController.shared?.data(withURL: imageURL)?.data
        }
        return searchableItem
    }
}

public class WMFSavedPageSpotlightManager: NSObject {
    private let queue = DispatchQueue(label: "org.wikimedia.saved_page_spotlight_manager", qos: DispatchQoS.background, attributes: [], autoreleaseFrequency: DispatchQueue.AutoreleaseFrequency.workItem, target: nil)
    private let dataStore: MWKDataStore
    @objc var savedPageList: MWKSavedPageList {
        return dataStore.savedPageList
    }
    
    @objc public required init(dataStore: MWKDataStore) {
        self.dataStore = dataStore
        super.init()
    }
    
    @objc public func reindexSavedPages() {
        self.savedPageList.enumerateItems { (item, stop) in
            guard let URL = item.url else {
                return
            }
            self.addToIndex(url: URL as NSURL)
        }
    }
    
    @objc public func addToIndex(url: NSURL) {
        guard let article = dataStore.fetchArticle(with: url as URL), let identifier = NSURL.wmf_desktopURL(for: url as URL)?.absoluteString else {
            return
        }
        
        queue.async {
            let searchableItemAttributes = article.searchableItemAttributes
            searchableItemAttributes.keywords?.append("Saved")
            
            let item = CSSearchableItem(uniqueIdentifier: identifier, domainIdentifier: "org.wikimedia.wikipedia", attributeSet: searchableItemAttributes)
            item.expirationDate = NSDate.distantFuture
            
            CSSearchableIndex.default().indexSearchableItems([item]) { (error) -> Void in
                if let error = error {
                    DDLogError("Indexing error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    @objc public func removeFromIndex(url: NSURL) {
        guard let identifier = NSURL.wmf_desktopURL(for: url as URL)?.absoluteString else {
            return
        }
        
        queue.async {
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [identifier]) { (error) in
                if let error = error {
                    DDLogError("Deindexing error: \(error.localizedDescription)")
                }
            }
        }

    }

}


