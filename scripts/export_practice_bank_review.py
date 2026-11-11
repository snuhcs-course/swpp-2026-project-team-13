"""Export human-readable results from the same shipped score manifest."""
import argparse,collections,csv,hashlib,json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1];CONTENT=ROOT/'backend/content'

def main(output):
    output.mkdir(parents=True,exist_ok=True)
    data=json.loads((CONTENT/'practice-difficulty.json').read_text(encoding='utf8'))
    audit=json.loads((CONTENT/'source/practice-bank/import-audit.json').read_text(encoding='utf8'))
    scores=json.loads((CONTENT/'source/practice-bank/scores.json').read_text(encoding='utf8'))
    catalog={}
    for name in ('catalog.json','additional-practice-catalog.json','sheet-revisions.json','practice-bank-catalog.json'):
        for item in json.loads((CONTENT/name).read_text(encoding='utf8')):catalog[item['metadata']['id']]=item['metadata']
    records=[]
    for qid,r in data['records'].items():
        q=catalog[qid]
        records.append(dict(id=qid,title=q['title'],level=r['level'],score=r['score'],
            content_score=r['content_score'],key_correction=r['key_correction'],
            fifths=q['key_signature']['fifths'],mode=q['key_signature']['mode'],
            meter=f'{q["time_signature"]["numerator"]}/{q["time_signature"]["denominator"]}',
            quarter_bpm=r['quarter_bpm'],source=r['source'],source_id=r['source_id']))
    records.sort(key=lambda r:(r['level'],r['score'],r['id']))
    with (output/'practice-bank.csv').open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,list(records[0]));w.writeheader();w.writerows(records)
    with (output/'excluded.csv').open('w',encoding='utf-8-sig',newline='') as f:
        fields=['source','source_id','reason','scored','source_sha256'];w=csv.DictWriter(f,fields,extrasaction='ignore');w.writeheader();w.writerows(audit['excluded'])
    with (output/'duplicates.csv').open('w',encoding='utf-8-sig',newline='') as f:
        fields=['source','source_id','canonical_question_id','source_sha256'];w=csv.DictWriter(f,fields,extrasaction='ignore');w.writeheader();w.writerows(audit['duplicates'])
    with (output/'all-scored-inputs.csv').open('w',encoding='utf-8-sig',newline='') as f:
        fields=['source','source_id','score','level','content_score','key_correction'];w=csv.DictWriter(f,fields);w.writeheader()
        for r in scores:w.writerow(dict(source=r['source'],source_id=r['source_id'],**{k:r['analysis'][k] for k in fields[2:]}))
    counts=collections.Counter(r['level'] for r in records)
    summary=dict(version=data['version'],input_count=audit['total'],scored=audit['scored'],
        practice_questions=len(records),duplicates=len(audit['duplicates']),excluded=len(audit['excluded']),
        level_counts=dict(sorted(counts.items())),cutoffs=data['cutoffs'],
        source_counts=dict(collections.Counter(r['source'] for r in records)),
        exclusion_reasons=dict(collections.Counter(r['reason'] for r in audit['excluded'])),
        highest_level_without_signature=sum(r['level']==9 and r['fifths']==0 for r in records),
        caveat='Initial content-anchor calibration; not validated learner success probabilities. Source-generated levels are not scoring inputs.')
    (output/'SUMMARY.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    lines=['Practice 문제은행 재분류 결과','2026-11-11 / '+data['version'],'',
        f'입력 자료 {audit["total"]}건 → 점수 계산 {audit["scored"]}건 → 실제 문제은행 {len(records)}문제.',
        f'중복 {len(audit["duplicates"])}건은 대표 문제에 연결했고, 출제 형식 미지원/표기 오류 {len(audit["excluded"])}건은 사유와 함께 보류했다.',
        '클래식은 분류·새 문제은행에서 제외했다. 새로 받은 1,000문제는 전부 포함했다.',
        '기존 중급은 Level 5, 고급 59문제는 Level 9가 되도록 기준점에 맞췄다.',
        '팀원의 기존 단계나 문제 출처를 점수 계산에 사용하지 않았다. 레벨별 문제 수를 맞추지는 않았다.','',
        '레벨 | 점수 범위 | 문제 수']
    edges=[0]+data['cutoffs']
    for level in range(1,10):
        band=f'{edges[level-1]:g} 이상'+(f' {edges[level]:g} 미만' if level<9 else '')
        lines.append(f'{level} | {band} | {counts[level]}')
    lines += ['',f'Level 9 중 조표 없는 문제: {summary["highest_level_without_signature"]}개.',
        '조표 때문에만 최고 레벨에 몰리는 방식이 아니다. 점수에는 100점 상한이 없다.',
        '원래 조성과 음높이·리듬은 유지했다. 기존에 검토한 원본 표기 교정 3건은 교정 전 원본도 별도로 보관했다.','',
        '구현',
        'Practice에 Level 1~9를 표시하고, 선택한 레벨 안에서 최종 점수 오름차순으로 제공한다.',
        '온라인 API와 로컬 데모가 같은 점수·커트라인을 사용한다.',
        '기존 ID와 저장된 응시는 유지한다. 중복으로 숨겨진 기존 문제도 과거 응시에서는 계속 열 수 있다.',
        '9레벨 표시는 8마디 전체 문제에만 적용한다. 부분 구간 점수에 같은 레벨 경계를 적용하지 않는다.','',
        '검증과 범위',
        '점수 재계산, 원본/번들 자산 해시, 전 문제 연결, 이조·템포·마디 경계·기존 기준 문제의 회귀 검사를 수행했다.',
        '신규 정답 이미지 1,827개의 오선 수를 검사해 4마디씩 두 줄로 배치했다.',
        '렌더링 49건은 최초 자동 줄바꿈 문제를 발견해 넓은 판형으로 재출력했다. 음정과 리듬은 변경하지 않았다.',
        'Python 콘텐츠·난이도·오선·재생·Feature 테스트 67개가 통과했다.',
        '이 환경에서는 Docker 엔진 접근이 거부되었고 Swift 도구가 없어 Django DB 통합 및 Swift/iPad 빌드는 실행하지 못했다.',
        '해당 검사는 GitHub CI에 연결했다. 이번 변경을 GitHub에 push하거나 서버에 배포하지는 않았다.',
        '레벨의 교육적 적합성과 조표/속도 계수는 실제 학생 풀이 데이터로 추가 검증해야 한다.','',
        '파일',
        'practice-bank.csv: 실제 배치 문항 전체, 최종 점수와 레벨',
        'all-scored-inputs.csv: 출제 보류 자료를 포함한 계산 결과; 8마디 전체 기준에 해당하지 않으면 level 비어 있음',
        'excluded.csv: 보류 문항과 사유',
        'duplicates.csv: 중복 문항과 대표 ID',
        '정확한 계산식과 정책: sori-github/docs/PRACTICE-DIFFICULTY-V1.txt']
    (output/'REVIEW.txt').write_text('\n'.join(lines)+'\n',encoding='utf-8-sig')
    print(json.dumps(summary,ensure_ascii=False,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=ROOT/'.tmp/practice-bank/review')
    a=p.parse_args();main(a.output)
