import Foundation

/// Only fixed command names may enter error codes; no input text, paths or IDs.
public enum LocalWorkerCommand: String, Codable, CaseIterable, Sendable {
    case directStart = "direct_start", directStep = "direct_step", directPause = "direct_pause"
    case styleTextPublish = "style_text_publish"
    case status, overview, prepare, context, contract, validate
    case indexStatus = "index_status", indexStart = "index_start", indexDiscovery = "index_discovery"
    case indexRewindMailbox = "index_rewind_mailbox"
    case indexNext = "index_next", indexPage = "index_page", indexFinish = "index_finish"
    case rankMailHeaders = "rank_mail_headers", mailSnapshot = "mail_snapshot"
    case mailBodyCacheLookup = "mail_body_cache_lookup", mailBodyCacheStore = "mail_body_cache_store"
    case register, registerStyleSource = "register_style_source", ingest
    case sourceMessageIDs = "source_message_ids", search, message
    case caseCreate = "case_create", cases, membership, caseDetail = "case_detail"
    case eventAdd = "event_add", policyAdd = "policy_add", policyRemove = "policy_remove"
    case styleAdd = "style_add", styleRemove = "style_remove", styleReplace = "style_replace"
    case styleSummary = "style_summary", styleExtract = "style_extract", styleCorpusExtract = "style_corpus_extract"
    case styleCaptureStart = "style_capture_start", styleCaptureStatus = "style_capture_status"
    case styleCapturePage = "style_capture_page", styleCaptureFinish = "style_capture_finish", styleCaptureExtract = "style_capture_extract"
    case styleCaptureContentPage = "style_capture_content_page"
    case styleCaptureReadBudget = "style_capture_read_budget", styleCaptureReadReserve = "style_capture_read_reserve"
    case styleCaptureReadCharge = "style_capture_read_charge"
    case profileData = "profile_data", deleteSource = "delete_source"

    public func failureCode(_ cause: String, allowed: Set<String>) -> String {
        "WORKER_" + rawValue.uppercased() + "__" + (allowed.contains(cause) ? cause : "LOCAL_OPERATION_FAILED")
    }
}
