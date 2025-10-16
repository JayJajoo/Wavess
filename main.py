"""
Complete LinkedIn Audience Intelligence & Post Performance System
"""

import pandas as pd
import json
import sys
from datetime import datetime

from partA import (
    process_linkedin_data,
    DICTIONARIES,
    ICP_CONFIG
)

from partB import (
    analyze_linkedin_post,
    save_post_analysis,
    generate_recommendations
)


class LinkedInIntelligenceSystem:
    
    def __init__(self, post_text: str = None, post_url: str = None):
        self.post_text = post_text
        self.post_url = post_url
        self.post_features = None
        self.audience_df = None
        self.timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    
    def analyze_post(self, verbose: bool = True):
        if not self.post_text:
            return None
        
        self.post_features = analyze_linkedin_post(self.post_text, verbose=verbose)
        
        save_post_analysis(
            self.post_features, 
            f"post_performance_analysis_{self.timestamp}.json"
        )
        
        return self.post_features
    
    def analyze_audience(self, input_csv: str, verbose: bool = True):
        output_csv = f"audience_intelligence_{self.timestamp}.csv"
        self.audience_df = process_linkedin_data(input_csv, output_csv)
        
        return self.audience_df
    
    def generate_combined_report(self):
        report_file = f"linkedin_intelligence_report_{self.timestamp}.txt"
        
        with open(report_file, 'w', encoding='utf-8') as f:
            f.write("="*80 + "\n")
            f.write("LINKEDIN AUDIENCE INTELLIGENCE & POST PERFORMANCE REPORT\n")
            f.write("="*80 + "\n\n")
            
            f.write(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            if self.post_url:
                f.write(f"Post URL: {self.post_url}\n")
            f.write("\n")
            
            if self.post_features:
                f.write("="*80 + "\n")
                f.write("POST PERFORMANCE ANALYSIS\n")
                f.write("="*80 + "\n\n")
                
                f.write(f"Performance Prediction: {self.post_features.predicted_performance.upper()}\n")
                f.write(f"Performance Score: {self.post_features.performance_score}/100\n")
                f.write(f"Score Factors: {self.post_features.performance_reason}\n\n")
                
                f.write("Feature Summary:\n")
                f.write(f"  - Word count: {self.post_features.word_count}\n")
                f.write(f"  - Has question: {self.post_features.has_question}\n")
                f.write(f"  - Hashtags: {self.post_features.hashtag_count}\n")
                f.write(f"  - Emojis: {self.post_features.emoji_count}\n")
                f.write(f"  - External link: {self.post_features.has_external_link}\n")
                f.write(f"  - Call to action: {self.post_features.has_call_to_action}\n\n")
                
                f.write(generate_recommendations(self.post_features))
            
            if self.audience_df is not None:
                f.write("\n" + "="*80 + "\n")
                f.write("AUDIENCE INTELLIGENCE ANALYSIS\n")
                f.write("="*80 + "\n\n")
                
                total = len(self.audience_df)
                excluded = self.audience_df['excluded'].sum()
                valid = total - excluded
                
                f.write(f"Total profiles analyzed: {total}\n")
                f.write(f"Valid profiles: {valid}\n")
                f.write(f"Excluded profiles: {excluded}\n\n")
                
                if valid > 0:
                    avg_score = self.audience_df[~self.audience_df['excluded']]['score'].mean()
                    high_value = (self.audience_df['score'] >= 70).sum()
                    
                    f.write(f"Average relevance score: {avg_score:.1f}/100\n")
                    f.write(f"High-value profiles (>=70): {high_value} ({high_value/valid*100:.1f}%)\n\n")
                    
                    f.write("Top Functions:\n")
                    function_counts = self.audience_df[~self.audience_df['excluded']]['role_function'].value_counts().head(5)
                    for func, count in function_counts.items():
                        f.write(f"  - {func}: {count} ({count/valid*100:.1f}%)\n")
                    f.write("\n")
                    
                    f.write("Seniority Distribution:\n")
                    seniority_counts = self.audience_df[~self.audience_df['excluded']]['seniority'].value_counts().head(5)
                    for level, count in seniority_counts.items():
                        f.write(f"  - {level}: {count} ({count/valid*100:.1f}%)\n")
                    f.write("\n")
                    
                    f.write("Geography Distribution:\n")
                    geo_counts = self.audience_df[~self.audience_df['excluded']]['geo'].value_counts().head(5)
                    for geo, count in geo_counts.items():
                        f.write(f"  - {geo}: {count} ({count/valid*100:.1f}%)\n")
                    f.write("\n")
                    
                    f.write("="*80 + "\n")
                    f.write("TOP 10 HIGHEST-VALUE PROSPECTS\n")
                    f.write("="*80 + "\n\n")
                    
                    top_10 = self.audience_df[~self.audience_df['excluded']].head(10)
                    for idx, row in top_10.iterrows():
                        f.write(f"{idx+1}. {row['name']} (Score: {row['score']})\n")
                        f.write(f"   {row['title']}\n")
                        f.write(f"   {row['seniority']} | {row['role_function']} | {row['company_type']} | {row['geo']}\n")
                        f.write(f"   Reason: {row['score_reason']}\n\n")
            
            if self.post_features and self.audience_df is not None:
                f.write("\n" + "="*80 + "\n")
                f.write("STRATEGIC INSIGHTS & RECOMMENDATIONS\n")
                f.write("="*80 + "\n\n")
                
                f.write("Post-Audience Alignment:\n")
                
                high_value_count = (self.audience_df['score'] >= 70).sum()
                total_valid = len(self.audience_df[~self.audience_df['excluded']])
                
                if total_valid > 0:
                    alignment_rate = (high_value_count / total_valid) * 100
                    
                    if alignment_rate >= 30:
                        f.write(f"STRONG alignment: {alignment_rate:.1f}% high-value audience\n")
                        f.write("   This post is resonating with your ICP. Continue similar content.\n\n")
                    elif alignment_rate >= 15:
                        f.write(f"MODERATE alignment: {alignment_rate:.1f}% high-value audience\n")
                        f.write("   Consider refining targeting or post theme.\n\n")
                    else:
                        f.write(f"WEAK alignment: {alignment_rate:.1f}% high-value audience\n")
                        f.write("   Review content strategy and targeting approach.\n\n")
                
                if self.post_features.performance_score < 70:
                    f.write("Content Optimization Priority:\n")
                    f.write("  Focus on improving post structure to increase reach.\n")
                    f.write("  Higher reach = more potential ICP engagement.\n\n")
                
                top_functions = self.audience_df[~self.audience_df['excluded']]['role_function'].value_counts().head(3)
                f.write("Engagement Strategy:\n")
                f.write(f"  Priority functions: {', '.join(top_functions.index.tolist())}\n")
                f.write("  - Engage directly with C-level and VP profiles\n")
                f.write("  - Create follow-up content for these functions\n")
                f.write("  - Consider targeted ads to similar profiles\n\n")
        
        print(f"Combined report saved: {report_file}")
        return report_file
    
    def export_prospect_list(self, min_score: int = 70):
        if self.audience_df is None:
            return None
        
        prospects = self.audience_df[
            (~self.audience_df['excluded']) & 
            (self.audience_df['score'] >= min_score)
        ].copy()
        
        if len(prospects) == 0:
            print(f"No prospects found with score >= {min_score}")
            return None
        
        def get_priority(row):
            if row['seniority'] in ['c_level', 'vp']:
                return 'HIGH'
            elif row['seniority'] == 'director':
                return 'MEDIUM'
            else:
                return 'LOW'
        
        prospects['outreach_priority'] = prospects.apply(get_priority, axis=1)
        
        outreach_df = prospects[[
            'name', 'title', 'company', 'role_function', 'seniority',
            'score', 'outreach_priority', 'score_reason'
        ]].copy()
        
        output_file = f"high_value_prospects_{self.timestamp}.csv"
        outreach_df.to_csv(output_file, index=False)
        
        print(f"Exported {len(outreach_df)} prospects: {output_file}")
        print(f"  HIGH priority: {(outreach_df['outreach_priority'] == 'HIGH').sum()}")
        print(f"  MEDIUM priority: {(outreach_df['outreach_priority'] == 'MEDIUM').sum()}")
        print(f"  LOW priority: {(outreach_df['outreach_priority'] == 'LOW').sum()}")
        
        return outreach_df


def main():
    print("LINKEDIN AUDIENCE INTELLIGENCE & POST PERFORMANCE SYSTEM\n")
    
    if len(sys.argv) < 2:
        print("Usage: python linkedin_complete_system.py <audience_csv> [post_text_file]")
        print("\nArguments:")
        print("  audience_csv     : CSV file with 'Name' and 'Title' columns")
        print("  post_text_file   : (Optional) Text file containing LinkedIn post")
        print("\nExample:")
        print("  python linkedin_complete_system.py linkedin_contacts.csv post.txt")
        sys.exit(1)
    
    audience_csv = sys.argv[1]
    post_text = None
    post_url = None
    
    if len(sys.argv) > 2:
        post_file = sys.argv[2]
        try:
            with open(post_file, 'r', encoding='utf-8') as f:
                post_text = f.read().strip()
            print(f"Loaded post text: {post_file}")
        except FileNotFoundError:
            print(f"Post file not found: {post_file}")
    
    if len(sys.argv) > 3:
        post_url = sys.argv[3]
    
    system = LinkedInIntelligenceSystem(post_text=post_text, post_url=post_url)
    
    if post_text:
        system.analyze_post(verbose=True)
    
    try:
        system.analyze_audience(audience_csv, verbose=True)
    except FileNotFoundError:
        print(f"Error: Audience CSV not found: {audience_csv}")
        sys.exit(1)
    except Exception as e:
        print(f"Error processing audience data: {e}")
        sys.exit(1)
    
    system.generate_combined_report()
    system.export_prospect_list(min_score=70)
    
    print("\nAnalysis complete")


if __name__ == "__main__":
    main()