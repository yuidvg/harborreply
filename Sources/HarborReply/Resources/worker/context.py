"""Evidence selection is deterministic and independent of writing style."""
import json
import re
from email.parser import Parser
from email import policy
from archive import ArchiveError, digest, packed, MAX_CASE_MESSAGES, authored_text

MAX_CONTEXT = 24000

def build_context(archive, current, case_id='', user_intent='', language='English', tone='丁寧・明確', style_profile='', request_id='', context_revision=0, related_selection=None):
    if related_selection is not None:
        if type(related_selection) is not dict or set(related_selection) != {'excluded_ids'} or type(related_selection['excluded_ids']) is not list or len(related_selection['excluded_ids']) > 600 or any(type(mid) is not str or len(mid) > 512 for mid in related_selection['excluded_ids']):
            raise ArchiveError('IPC_REQUEST_INVALID')
    if related_selection is not None: case_id = ''
    revision = archive.revision()
    chosen = {}; candidates = []; unresolved = []
    # Header graph suggestions are visible; never silently merge multiple cases in one thread.
    header = current.get('messageID', '').strip('<>')
    if header:
        for mid in archive.header_message_ids(header, MAX_CASE_MESSAGES + 1):
            chosen[mid] = 'current_message_match'
    if len(chosen) > MAX_CASE_MESSAGES: raise ArchiveError('HEADER_COLLISION_LIMIT')
    parsed_headers = Parser(policy=policy.default).parsestr(current.get('headers', ''), headersonly=True)
    header_refs = re.findall(r'<([^<>\s]+)>', str(parsed_headers.get('References', '')) + ' ' + str(parsed_headers.get('In-Reply-To', '')))
    if len(chosen) > 1:
        unresolved.append('同じMessage-IDで内容が異なる履歴があります。原文を確認して案件を指定してください。')
    if len(header_refs) > 60: raise ArchiveError('HEADER_REFERENCES_LIMIT')
    for parent in list(dict.fromkeys([header] + header_refs)):
        if not parent: continue
        for children in (False, True):
            for mid in archive.header_message_ids(parent, 60, children):
                if mid not in candidates: candidates.append(mid)
                if len(candidates) >= 60: break
            if len(candidates) >= 60: break
        if len(candidates) >= 60: break
    # Header relationships lead. Lexically ranked metadata supplements them,
    # while every automatic candidate stays unconfirmed and outside evidence.
    subject_candidates = False
    candidate_reasons = {mid: 'reply_header' for mid in candidates}
    if not case_id and len(candidates) < 60 and (current.get('subject', '').strip() or current.get('sender', '').strip()):
        for match in archive.related_candidates(current, 60):
            mid = match['id']
            if mid not in candidates: candidates.append(mid); subject_candidates = True; candidate_reasons[mid] = match['reason']
            if len(candidates) >= 60: break
    if related_selection is not None:
        candidates = [mid for mid in candidates if chosen.get(mid) != 'current_message_match']
    events = []
    if case_id:
        unresolved = []
        if not archive.db.execute('SELECT 1 FROM cases WHERE id=?', (case_id,)).fetchone(): raise ArchiveError('CASE_NOT_FOUND')
        chosen = {mid: 'confirmed_case' for mid in archive.case_message_ids(case_id)}
        events = archive.case_events(case_id)
        for event in events: chosen[event['message_id']] = 'case_event_evidence'
    elif set(candidates) - set(chosen):
        unresolved.append('件名検索の候補があります。原文を確認して案件へ追加してください。' if subject_candidates else '返信関係の候補があります。別航海・別貨物の混在を確認して案件へ追加してください。')
    if related_selection is not None:
        excluded = set(related_selection['excluded_ids'])
        chosen = {mid: 'selected_related' for mid in candidates if mid not in excluded}
        unresolved = []
    evidence = []
    current_text = current.get('body', '')
    if len(current_text) > 12000: raise ArchiveError('CURRENT_MESSAGE_TOO_LARGE')
    evidence.append({'id': 'E1', 'message_id': current.get('id', ''), 'text': current_text,
                     'subject': current.get('subject', ''), 'reason': 'selected_current', 'body_hash': digest(current_text.encode()), 'internal': current.get('internal', False)})
    budget = len(current_text)
    warnings = ['履歴は指定ファイルのスナップショットです。別スレッドの新着・最新の送信済みを含むとは限りません。']
    for mid, reason in chosen.items():
        m = archive.message(mid)
        if m['source_status'] != 'available':
            if related_selection is not None:
                warnings.append('本文を取得できない関連メールは入力から除外しました。'); continue
            raise ArchiveError('EVIDENCE_SOURCE_MISSING_OR_CHANGED')
        if related_selection is None and m['direction'] in ('draft', 'unknown'):
            warnings.append('下書きまたは送受信区分不明のメールを根拠から除外しました。'); continue
        if m['body_text'] == current_text and not any(e['message_id'] == mid for e in events): continue
        text = m['body_text']
        if related_selection is not None:
            limit = max(1, min(2000, (MAX_CONTEXT - len(current_text) - 8000) // max(1, len(chosen))))
            text = text[:limit]
            if len(text) < len(m['body_text']): warnings.append('長い関連メールは本文の先頭を抜粋しています。')
            if m['direction'] in ('draft', 'unknown'): warnings.append('関連メールの送受信区分が不明、または下書きです。送信済みの発言や承認とは扱わないでください。')
        budget += len(text)
        if budget > MAX_CONTEXT: raise ArchiveError('REQUIRED_EVIDENCE_EXCEEDS_CONTEXT')
        evidence.append({'id': 'E' + str(len(evidence)+1), 'message_id': mid, 'text': text,
                         'subject': m['subject'], 'date': m['date'], 'from': m['from'], 'reason': reason,
                         'body_hash': m['body_hash'], 'internal': m['internal'], 'attachments': m['attachments'], 'direction': m['direction']})
        if m['attachments']: warnings.append('未解析添付があります。添付受領と内容確認は別です。')
        if m.get('origin') in ('apple_mail_readonly_snapshot', 'apple_mail_index_snapshot'): warnings.append('Mailの取得時点のテキスト写しです。原本MIME・添付内容・現在のMail原本は照合していません。')
    for event in events:
        e = next((e for e in evidence if e['message_id'] == event['message_id']), None)
        if e is None or event['body_hash'] != e['body_hash'] or event['quote'] not in e['text']:
            raise ArchiveError('EVENT_EVIDENCE_STALE')
        event['evidence_id'] = e['id']
        event['review_status'] = 'user_confirmed' if event['confirmed'] else 'unconfirmed'
    examples = []
    style_messages = archive.selected_style_messages()
    for m in style_messages:
        # Only deliberately selected examples; not permitted evidence for current facts.
        text = authored_text(m['body_text'])
        if not text: continue
        if budget + len(text) < MAX_CONTEXT:
            examples.append({'text': text, 'purpose': 'style_only_not_facts'}); budget += len(text)
        else: warnings.append('入力上限のため文体例を省略しました。')
    policies = archive.policies()
    policy_budget = sum(len(p['text']) for p in policies)
    style_summary = archive.style_summary(verified_messages=style_messages)
    if budget + policy_budget + len(user_intent) + len(style_profile) + len(packed(style_summary)) > MAX_CONTEXT:
        raise ArchiveError('CONTEXT_LIMIT_NARROW_REQUIRED')
    for index, p in enumerate(policies):
        p['evidence_id'] = 'P' + str(index+1)
        p.pop('source', None)  # Keep original references local; the provider needs the verified excerpt.
        p['applies_confirmed'] = bool(p.get('applies_confirmed') and case_id and p.get('applies_case_id') == case_id)
        if not p.get('applies_confirmed'): warnings.append('登録規程の今回の案件への適用を確認してください。')
    coverage = archive.coverage()
    if archive.revision() != revision: raise ArchiveError('ARCHIVE_CHANGED_DURING_RETRIEVAL')
    return {'request_id': request_id, 'context_revision': context_revision, 'archive_revision': revision,
            'user_intent': user_intent, 'reply_language': language, 'tone': tone,
            'current_message': {k: current.get(k, '') for k in ('subject', 'sender', 'body')},
            'thread_evidence': evidence, 'case_events': events, 'style_profile': style_profile,
            'style_summary': style_summary,
            'style_examples': examples, 'approved_policy_excerpts': policies, 'coverage': coverage,
            'unresolved_items': unresolved, 'local_warnings': list(dict.fromkeys(warnings)),
            'candidate_ids': [mid for mid in dict.fromkeys(candidates) if related_selection is not None or mid not in chosen][:60],
            'candidate_reasons': candidate_reasons}
