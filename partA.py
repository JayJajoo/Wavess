"""
LinkedIn Audience Intelligence & Relevance Scoring System
"""

import pandas as pd
import json
import re
from typing import Dict, Tuple, List
from dataclasses import dataclass


DICTIONARIES = {
    "functions": {
        "climate": ["climate", "sustainability", "esg", "environmental", "carbon", "impact"],
        "finance": ["finance", "financial", "treasury", "accounting", "cfo"],
        "risk": ["risk", "compliance", "aml", "regulatory", "governance"],
        "technology": ["engineer", "developer", "tech", "software", "data", "ai", "ml", "genai"],
        "marketing": ["marketing", "brand", "communications", "pr", "content", "creative"],
        "sales": ["sales", "business development", "bd", "account", "partnership", "gtm"],
        "product": ["product", "pm", "product manager"],
        "operations": ["operations", "ops", "delivery", "project management"],
        "hr": ["people", "hr", "human resources", "talent"],
        "executive": ["ceo", "coo", "cto", "cfo", "cmo", "founder", "co-founder", "president", "chief"]
    },
    
    "seniority": {
        "c_level": ["ceo", "cto", "cfo", "cmo", "coo", "cio", "chief", "president"],
        "vp": ["vp", "vice president", "svp", "evp"],
        "director": ["director", "head of"],
        "manager": ["manager", "lead", "principal"],
        "senior": ["senior", "sr.", "sr "],
        "mid": ["specialist", "analyst", "engineer", "developer", "consultant"],
        "entry": ["junior", "associate", "assistant", "coordinator"]
    },
    
    "company_types": {
        "fintech": ["klarna", "stripe", "paypal", "square", "revolut", "wise", "fintech"],
        "consulting": ["mckinsey", "bcg", "bain", "pwc", "ey", "deloitte", "kpmg", "accenture"],
        "tech": ["google", "microsoft", "amazon", "apple", "meta", "ibm", "salesforce"],
        "finance": ["bank", "capital", "investment", "venture", "fund", "financial"],
        "climate_tech": ["climate", "sustainability", "carbon", "renewable", "green", "environmental"],
        "startup": ["startup", "founder", "co-founder", "venture"],
        "enterprise": ["enterprise", "corporation", "global", "multinational"]
    },
    
    "geographies": {
        "nordics": ["sweden", "norway", "denmark", "finland", "stockholm", "oslo", "copenhagen", "helsinki", "nordic"],
        "europe": ["uk", "germany", "france", "spain", "italy", "portugal", "netherlands", "europe", "emea"],
        "north_america": ["usa", "us", "canada", "north america", "americas"],
        "apac": ["apac", "asia", "australia", "singapore", "japan", "china", "anz"],
        "latam": ["latam", "latin america", "brazil", "mexico"]
    }
}

POST_KEYWORDS = ["climate", "resilience", "sustainability", "carbon", "environmental"]

EXCLUSIONS = [
    "competitor_company_name",
    "spam",
    "bot"
]

ICP_CONFIG = {
    "target_functions": ["climate", "sustainability", "finance", "risk", "executive"],
    "target_seniority": ["c_level", "vp", "director"],
    "target_company_types": ["fintech", "finance", "climate_tech", "enterprise"],
    "target_geo": ["nordics", "europe"]
}


@dataclass
class ParsedProfile:
    name: str
    title: str
    company: str
    role_function: str
    seniority: str
    company_type: str
    geo: str
    score: int
    score_reason: str
    excluded: bool


def extract_company(title: str) -> str:
    patterns = [
        r'@\s*([^|]+?)(?:\s*\||$)',
        r'\bat\b\s+([^|]+?)(?:\s*\||$)',
        r'på\s+([^|]+?)(?:\s*\||$)',
    ]
    
    for pattern in patterns:
        match = re.search(pattern, title, re.IGNORECASE)
        if match:
            return match.group(1).strip()
    
    return "Unknown"


def classify_function(title: str) -> str:
    title_lower = title.lower()
    
    for function, keywords in DICTIONARIES["functions"].items():
        for keyword in keywords:
            if keyword in title_lower:
                return function
    
    return "general"


def classify_seniority(title: str) -> str:
    title_lower = title.lower()
    
    for level, keywords in DICTIONARIES["seniority"].items():
        for keyword in keywords:
            if keyword in title_lower:
                return level
    
    return "mid"


def classify_company_type(title: str, company: str) -> str:
    text_lower = f"{title} {company}".lower()
    
    for comp_type, keywords in DICTIONARIES["company_types"].items():
        for keyword in keywords:
            if keyword in text_lower:
                return comp_type
    
    return "other"


def classify_geography(title: str) -> str:
    title_lower = title.lower()
    
    for geo, keywords in DICTIONARIES["geographies"].items():
        for keyword in keywords:
            if keyword in title_lower:
                return geo
    
    return "unknown"


def check_exclusions(title: str, company: str) -> bool:
    text_lower = f"{title} {company}".lower()
    
    for exclusion in EXCLUSIONS:
        if exclusion.lower() in text_lower:
            return True
    
    return False


def calculate_relevance_score(
    role_function: str,
    seniority: str,
    company_type: str,
    geo: str,
    title: str
) -> Tuple[int, str]:
    """
    Calculate relevance score (0-100) based on:
    - Function: +40 (exact), +20 (adjacent)
    - Seniority: +25 (exact), +10 (near)
    - Company: +20 (exact), +10 (adjacent)
    - Geography: +10
    - Keywords: +5 each (max +10)
    """
    score = 0
    reasons = []
    
    if role_function in ICP_CONFIG["target_functions"]:
        score += 40
        reasons.append("Function")
    elif role_function in ["sales", "marketing", "product"]:
        score += 20
        reasons.append("Function(partial)")
    
    if seniority in ICP_CONFIG["target_seniority"]:
        score += 25
        reasons.append("Seniority")
    elif seniority == "manager":
        score += 10
        reasons.append("Seniority(near)")
    
    if company_type in ICP_CONFIG["target_company_types"]:
        score += 20
        reasons.append("CompanyType")
    elif company_type in ["consulting", "tech"]:
        score += 10
        reasons.append("CompanyType(adjacent)")
    
    if geo in ICP_CONFIG["target_geo"]:
        score += 10
        reasons.append("Geo")
    
    title_lower = title.lower()
    keyword_matches = sum(1 for kw in POST_KEYWORDS if kw in title_lower)
    keyword_score = min(keyword_matches * 5, 10)
    if keyword_score > 0:
        score += keyword_score
        reasons.append(f"Keywords(+{keyword_score})")
    
    score = min(score, 100)
    score_reason = "+".join(reasons) if reasons else "NoMatch"
    
    return score, score_reason


def process_linkedin_data(input_csv: str, output_csv: str = "audience_intelligence_output.csv") -> pd.DataFrame:
    df = pd.read_csv(input_csv)
    
    if 'Name' not in df.columns or 'Title' not in df.columns:
        raise ValueError("Input CSV must have 'Name' and 'Title' columns")
    
    results = []
    
    for _, row in df.iterrows():
        name = row['Name']
        title = row['Title']
        
        if 'followers' in title.lower():
            continue
        
        company = extract_company(title)
        role_function = classify_function(title)
        seniority = classify_seniority(title)
        company_type = classify_company_type(title, company)
        geo = classify_geography(title)
        excluded = check_exclusions(title, company)
        
        if excluded:
            score = -100
            score_reason = "Excluded"
        else:
            score, score_reason = calculate_relevance_score(
                role_function, seniority, company_type, geo, title
            )
        
        results.append({
            'name': name,
            'title': title,
            'company': company,
            'role_function': role_function,
            'seniority': seniority,
            'company_type': company_type,
            'geo': geo,
            'score': score,
            'score_reason': score_reason,
            'excluded': excluded
        })
    
    result_df = pd.DataFrame(results)
    
    seniority_order = ['c_level', 'vp', 'director', 'manager', 'senior', 'mid', 'entry']
    result_df['seniority_rank'] = result_df['seniority'].apply(
        lambda x: seniority_order.index(x) if x in seniority_order else len(seniority_order)
    )
    result_df = result_df.sort_values(['score', 'seniority_rank'], ascending=[False, True])
    result_df = result_df.drop('seniority_rank', axis=1)
    
    result_df.to_csv(output_csv, index=False)
    
    print(f"Processed {len(result_df)} profiles")
    print(f"Excluded: {result_df['excluded'].sum()}")
    print(f"High-value (≥70): {(result_df['score'] >= 70).sum()}")
    print(f"Output: {output_csv}")
    
    return result_df


def run_unit_tests():
    test_cases = [
        {"title": "Global Lead, Risk & Compliance @ Klarna", "expected_function": "risk", "expected_seniority": "manager", "expected_company": "Klarna"},
        {"title": "VP GTM @ TechCorp | Board Advisor", "expected_function": "sales", "expected_seniority": "vp", "expected_company": "TechCorp"},
        {"title": "Interim Head Product Risk at FinanceInc", "expected_function": "risk", "expected_seniority": "director", "expected_company": "FinanceInc"},
        {"title": "Chief Sustainability Officer | Climate Tech Investor", "expected_function": "climate", "expected_seniority": "c_level", "expected_company": "Unknown"},
        {"title": "Senior Engineering Manager @ Klarna | Applied AI", "expected_function": "technology", "expected_seniority": "manager", "expected_company": "Klarna"},
        {"title": "Head of Climate and Environment at Klarna", "expected_function": "climate", "expected_seniority": "director", "expected_company": "Klarna"},
        {"title": "Co-founder BLING, Investor", "expected_function": "executive", "expected_seniority": "c_level", "expected_company": "BLING"},
        {"title": "Partner Success Lead @Milkywire", "expected_function": "sales", "expected_seniority": "manager", "expected_company": "Milkywire"}
    ]
    
    passed = 0
    failed = 0
    
    for i, test in enumerate(test_cases, 1):
        title = test["title"]
        company = extract_company(title)
        function = classify_function(title)
        seniority = classify_seniority(title)
        
        if company == test["expected_company"] and function == test["expected_function"] and seniority == test["expected_seniority"]:
            passed += 1
        else:
            print(f"Test {i} failed: {title}")
            failed += 1
    
    print(f"Tests: {passed}/{len(test_cases)} passed")


if __name__ == "__main__":
    import sys
    
    run_unit_tests()
    
    if len(sys.argv) > 1:
        input_file = sys.argv[1]
        output_file = sys.argv[2] if len(sys.argv) > 2 else "audience_intelligence_output.csv"
    else:
        input_file = "linkedin_contacts.csv"
        output_file = "audience_intelligence_output.csv"
    
    try:
        result_df = process_linkedin_data(input_file, output_file)
        
        with open("dictionaries.json", "w") as f:
            json.dump(DICTIONARIES, f, indent=2)
            
    except FileNotFoundError:
        print(f"Error: '{input_file}' not found")
        print("Usage: python script.py <input_csv> [output_csv]")
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)