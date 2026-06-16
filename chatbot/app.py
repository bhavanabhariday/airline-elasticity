import streamlit as st
import pandas as pd
from groq import Groq

# ── Page config ──────────────────────────────────────────────────────────────
st.set_page_config(
    page_title="Airline Pricing Assistant",
    page_icon="✈️",
    layout="wide"
)

# ── Load data ─────────────────────────────────────────────────────────────────
BASE_URL = "https://raw.githubusercontent.com/bhavanabhariday/airline-elasticity/main/data/output"

@st.cache_data
def load_data():
    elasticity  = pd.read_csv(f"{BASE_URL}/elasticity_estimates.csv")
    revenue     = pd.read_csv(f"{BASE_URL}/revenue_opportunities.csv")
    sensitivity = pd.read_csv(f"{BASE_URL}/fare_sensitivity_curves.csv")
    return elasticity, revenue, sensitivity

elasticity_df, revenue_df, sensitivity_df = load_data()

# ── Build data context for the model ─────────────────────────────────────────
def build_context():
    raise_fare = revenue_df[revenue_df["recommendation"] == "Raise Fare"][
        ["route", "fare_tier", "elasticity", "current_fare", "optimal_fare",
         "rev_delta", "opportunity_tier"]
    ].to_string(index=False)

    top_elastic = elasticity_df[elasticity_df["elasticity_sig"] == True].nsmallest(10, "elasticity")[
        ["route", "fare_tier", "elasticity", "demand_type", "ulcc_share"]
    ].to_string(index=False)

    top_inelastic = elasticity_df[elasticity_df["elasticity_sig"] == True].nlargest(10, "elasticity")[
        ["route", "fare_tier", "elasticity", "demand_type", "ulcc_share"]
    ].to_string(index=False)

    top_ulcc = elasticity_df[elasticity_df["elasticity_sig"] == True].nlargest(10, "ulcc_share")[
        ["route", "fare_tier", "ulcc_share", "elasticity", "demand_type"]
    ].to_string(index=False)

    return f"""
You are an Airline Revenue Management AI assistant. You have access to real fare elasticity
and revenue opportunity data from a statistical analysis of 120 million U.S. domestic flight
records (2022-2024, DOT DB1B dataset).

KEY FACTS:
- Total routes analyzed: 125
- Fare tiers: Coach Full, Coach Discounted, Business
- Elasticity threshold: -1.0 (above = inelastic/raise fare, below = elastic/hold or lower)
- ULCC = Ultra-Low-Cost Carriers (Spirit, Frontier, Allegiant)
- ulcc_share = fraction of passengers on that route carried by ULCCs (0 to 1)
- Higher ulcc_share = more ULCC competition = passengers more price sensitive

TOP ROUTES TO RAISE FARE:
{raise_fare}

MOST ELASTIC ROUTES (do NOT raise fares — below -1.0):
{top_elastic}

MOST INELASTIC ROUTES (safe to raise fares — above -1.0):
{top_inelastic}

ROUTES WITH MOST ULCC COMPETITION (highest ulcc_share):
{top_ulcc}

RULES FOR ANSWERING:
- Be concise and direct
- Elasticity above -1.0 (e.g. -0.3, -0.5) = inelastic = RAISE fares
- Elasticity below -1.0 (e.g. -1.5, -4.3) = elastic = do NOT raise fares
- Always mention the elasticity score when discussing a specific route
- Translate elasticity into plain English (e.g. "a 10% fare increase would drop demand by X%")
- Always mention ulcc_share when asked about ULCC competition
- If asked about a route not in the data, say so clearly
- Format numbers cleanly (e.g. $577K, -4.3, 45% ULCC share)
"""

# ── Groq client ───────────────────────────────────────────────────────────────
client = Groq(api_key=st.secrets["GROQ_API_KEY"])

# ── UI ────────────────────────────────────────────────────────────────────────
st.title("✈️ Airline Pricing Assistant")
st.caption("Ask me anything about fare elasticity and pricing opportunities across 125 U.S. routes.")

# Sidebar with quick stats
with st.sidebar:
    st.header("Quick Stats")
    st.metric("Routes Analyzed", "125")
    st.metric("Raise Fare Opportunities", len(revenue_df[revenue_df["recommendation"] == "Raise Fare"]))
    st.metric("Significant Elasticities", int(elasticity_df["elasticity_sig"].sum()))

    st.divider()
    st.subheader("Try asking:")
    st.markdown("""
- Which routes should I raise fares on?
- What is the elasticity of HNL-KOA?
- Which routes have the most ULCC competition?
- What happens if I raise fares 10% on ANC-ORD?
- Which routes are safest to raise fares?
- What is the top revenue opportunity?
    """)

# Chat history
if "messages" not in st.session_state:
    st.session_state.messages = []

# Display chat history
for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])

# Chat input
if prompt := st.chat_input("Ask about routes, fares, elasticity..."):
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    with st.chat_message("assistant"):
        with st.spinner("Thinking..."):
            response = client.chat.completions.create(
                model="llama-3.3-70b-versatile",
                messages=[
                    {"role": "system", "content": build_context()},
                    *[{"role": m["role"], "content": m["content"]}
                      for m in st.session_state.messages]
                ],
                temperature=0.3,
                max_tokens=1024
            )
            answer = response.choices[0].message.content
            st.markdown(answer)

    st.session_state.messages.append({"role": "assistant", "content": answer})
