"""
LinkedIn Post Performance Analyzer
"""

import re
import json
from typing import Dict, Tuple
from dataclasses import dataclass, asdict


@dataclass
class PostFeatures:
    word_count: int
    char_count: int
    has_question: bool
    question_count: int
    hashtag_count: int
    emoji_count: int
    has_external_link: bool
    link_count: int
    has_line_breaks: bool
    paragraph_count: int
    has_call_to_action: bool
    mentions_count: int
    all_caps_words: int
    exclamation_count: int
    post_length_category: str
    predicted_performance: str
    performance_score: int
    performance_reason: str


PERFORMANCE_RULES = {
    "optimal_word_count": (100, 200),
    "optimal_hashtags": (3, 5),
    "optimal_paragraphs": (3, 5),
    
    "cta_phrases": [
        "learn more", "read more", "click here", "sign up", "register",
        "join us", "get started", "download", "check out", "discover",
        "explore", "find out", "see how", "book", "apply", "comment below",
        "share your", "what do you think", "tell us", "let us know"
    ],
    
    "engagement_boosters": [
        "question", "?", "what", "how", "why", "share", "thoughts",
        "experience", "story", "announcement", "excited", "proud"
    ]
}


def extract_post_features(post_text: str) -> PostFeatures:
    word_count = len(post_text.split())
    char_count = len(post_text)
    
    question_count = post_text.count('?')
    has_question = question_count > 0
    
    hashtag_count = len(re.findall(r'#\w+', post_text))
    
    emoji_pattern = re.compile(
        "["
        "\U0001F600-\U0001F64F"
        "\U0001F300-\U0001F5FF"
        "\U0001F680-\U0001F6FF"
        "\U0001F1E0-\U0001F1FF"
        "\U00002702-\U000027B0"
        "\U000024C2-\U0001F251"
        "]+",
        flags=re.UNICODE
    )
    emoji_count = len(emoji_pattern.findall(post_text))
    
    link_pattern = r'https?://(?:www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b(?:[-a-zA-Z0-9()@:%_\+.~#?&/=]*)'
    links = re.findall(link_pattern, post_text)
    link_count = len(links)
    has_external_link = link_count > 0
    
    has_line_breaks = '\n' in post_text
    paragraphs = [p.strip() for p in post_text.split('\n') if p.strip()]
    paragraph_count = len(paragraphs)
    
    post_lower = post_text.lower()
    has_call_to_action = any(cta in post_lower for cta in PERFORMANCE_RULES["cta_phrases"])
    
    mentions_count = len(re.findall(r'@\w+', post_text))
    
    words = post_text.split()
    all_caps_words = sum(
        1 for word in words 
        if word.isupper() and len(word) > 2 and not word.startswith('#')
    )
    
    exclamation_count = post_text.count('!')
    
    if word_count < 50:
        post_length_category = "short"
    elif word_count < 150:
        post_length_category = "medium"
    elif word_count < 300:
        post_length_category = "long"
    else:
        post_length_category = "very_long"
    
    predicted_performance, performance_score, performance_reason = predict_performance(
        word_count=word_count,
        has_question=has_question,
        hashtag_count=hashtag_count,
        emoji_count=emoji_count,
        has_external_link=has_external_link,
        has_call_to_action=has_call_to_action,
        paragraph_count=paragraph_count,
        post_text=post_text
    )
    
    return PostFeatures(
        word_count=word_count,
        char_count=char_count,
        has_question=has_question,
        question_count=question_count,
        hashtag_count=hashtag_count,
        emoji_count=emoji_count,
        has_external_link=has_external_link,
        link_count=link_count,
        has_line_breaks=has_line_breaks,
        paragraph_count=paragraph_count,
        has_call_to_action=has_call_to_action,
        mentions_count=mentions_count,
        all_caps_words=all_caps_words,
        exclamation_count=exclamation_count,
        post_length_category=post_length_category,
        predicted_performance=predicted_performance,
        performance_score=performance_score,
        performance_reason=performance_reason
    )


def predict_performance(
    word_count: int,
    has_question: bool,
    hashtag_count: int,
    emoji_count: int,
    has_external_link: bool,
    has_call_to_action: bool,
    paragraph_count: int,
    post_text: str
) -> Tuple[str, int, str]:
    """
    Scoring: Word count (+20), Hashtags (+15), Question (+15), 
    CTA (+15), Structure (+10), Emojis (+10), Link (+10), Keywords (+5)
    """
    score = 0
    reasons = []
    
    optimal_min, optimal_max = PERFORMANCE_RULES["optimal_word_count"]
    if optimal_min <= word_count <= optimal_max:
        score += 20
        reasons.append("OptimalLength")
    elif 50 <= word_count < optimal_min or optimal_max < word_count <= 300:
        score += 10
        reasons.append("GoodLength")
    elif word_count < 50:
        score += 5
        reasons.append("TooShort")
    else:
        score += 5
        reasons.append("TooLong")
    
    optimal_hashtag_min, optimal_hashtag_max = PERFORMANCE_RULES["optimal_hashtags"]
    if optimal_hashtag_min <= hashtag_count <= optimal_hashtag_max:
        score += 15
        reasons.append("OptimalHashtags")
    elif 1 <= hashtag_count < optimal_hashtag_min or optimal_hashtag_max < hashtag_count <= 7:
        score += 8
        reasons.append("GoodHashtags")
    elif hashtag_count > 7:
        score += 3
        reasons.append("TooManyHashtags")
    
    if has_question:
        score += 15
        reasons.append("HasQuestion")
    
    if has_call_to_action:
        score += 15
        reasons.append("HasCTA")
    
    optimal_para_min, optimal_para_max = PERFORMANCE_RULES["optimal_paragraphs"]
    if optimal_para_min <= paragraph_count <= optimal_para_max:
        score += 10
        reasons.append("GoodStructure")
    elif 1 <= paragraph_count < optimal_para_min:
        score += 5
        reasons.append("SingleParagraph")
    
    if 1 <= emoji_count <= 3:
        score += 10
        reasons.append("GoodEmojis")
    elif emoji_count > 3:
        score += 5
        reasons.append("ManyEmojis")
    
    if has_external_link:
        score += 10
        reasons.append("HasLink")
    
    post_lower = post_text.lower()
    engagement_word_count = sum(
        1 for keyword in PERFORMANCE_RULES["engagement_boosters"]
        if keyword in post_lower
    )
    if engagement_word_count >= 2:
        score += 5
        reasons.append("EngagementWords")
    
    if score >= 75:
        prediction = "overperform"
    elif score >= 50:
        prediction = "average"
    else:
        prediction = "underperform"
    
    reason_string = "+".join(reasons) if reasons else "NoOptimization"
    
    return prediction, score, reason_string


def generate_post_report(features: PostFeatures, post_text: str) -> str:
    report = f"""
{'='*70}
LINKEDIN POST PERFORMANCE ANALYSIS
{'='*70}

POST PREVIEW:
{post_text[:200]}{'...' if len(post_text) > 200 else ''}

{'='*70}
FEATURE PROFILE
{'='*70}

Basic Metrics:
   Word count: {features.word_count}
   Character count: {features.char_count}
   Post length: {features.post_length_category}

Engagement Elements:
   Has question: {features.has_question}
   Question count: {features.question_count}
   Call to action: {features.has_call_to_action}

Formatting:
   Hashtags: {features.hashtag_count}
   Emojis: {features.emoji_count}
   Paragraphs: {features.paragraph_count}
   Line breaks: {features.has_line_breaks}

Links & Mentions:
   External link: {features.has_external_link}
   Link count: {features.link_count}
   Mentions: {features.mentions_count}

Style Indicators:
   ALL CAPS words: {features.all_caps_words}
   Exclamation marks: {features.exclamation_count}

{'='*70}
PERFORMANCE PREDICTION
{'='*70}

Predicted Performance: {features.predicted_performance.upper()}
Performance Score: {features.performance_score}/100
Score Factors: {features.performance_reason}

"""
    
    report += generate_recommendations(features)
    
    return report


def generate_recommendations(features: PostFeatures) -> str:
    recommendations = []
    
    if features.word_count < 100:
        recommendations.append("• Expand content to 100-200 words for optimal engagement")
    elif features.word_count > 300:
        recommendations.append("• Consider shortening to under 300 words (attention span)")
    
    if features.hashtag_count == 0:
        recommendations.append("• Add 3-5 relevant hashtags to increase discoverability")
    elif features.hashtag_count > 7:
        recommendations.append("• Reduce hashtags to 3-5 for better performance")
    
    if not features.has_question:
        recommendations.append("• Add a question to boost engagement (e.g., 'What's your experience?')")
    
    if not features.has_call_to_action:
        recommendations.append("• Include a clear call-to-action (e.g., 'Learn more', 'Comment below')")
    
    if features.paragraph_count < 3:
        recommendations.append("• Break text into 3-5 short paragraphs for readability")
    
    if features.emoji_count == 0:
        recommendations.append("• Add 1-2 relevant emojis to increase visual appeal")
    elif features.emoji_count > 3:
        recommendations.append("• Reduce emojis to 1-3 for professional tone")
    
    if recommendations:
        rec_text = "\nRECOMMENDATIONS:\n" + "\n".join(recommendations) + "\n"
    else:
        rec_text = "\nPost is well-optimized! No major recommendations.\n"
    
    return rec_text


def save_post_analysis(features: PostFeatures, output_file: str = "post_performance_analysis.json"):
    with open(output_file, 'w') as f:
        json.dump(asdict(features), f, indent=2)
    print(f"Analysis saved: {output_file}")


def analyze_linkedin_post(post_text: str, verbose: bool = True) -> PostFeatures:
    features = extract_post_features(post_text)
    
    if verbose:
        report = generate_post_report(features, post_text)
        print(report)
    
    return features


if __name__ == "__main__":
    sample_post = """
🌍 Exciting news! Klarna's Climate Resilience Program is now live.

We're committed to reducing our carbon footprint by 50% by 2030. Our new program includes:

✅ Carbon offset initiatives
✅ Sustainable supply chain partnerships  
✅ Green technology investments

This is just the beginning of our sustainability journey. 

What steps is your company taking towards climate resilience? 

Learn more: https://klarna.com/climate

#Sustainability #ClimateAction #ESG #GreenTech #CorporateResponsibility
"""
    
    features = analyze_linkedin_post(sample_post)
    save_post_analysis(features)