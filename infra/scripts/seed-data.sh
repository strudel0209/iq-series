#!/bin/bash
set -e

echo "[1/4] Waiting 90 seconds for RBAC role propagation..."
sleep 90

echo "[2/4] Installing Python dependencies..."
pip install --break-system-packages -q azure-search-documents==11.7.0b2 azure-identity requests

echo "[3/4] Running data seed script..."
python3 <<'PYTHON_SCRIPT'
import os, json, requests
from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from azure.search.documents.indexes import SearchIndexClient
from azure.search.documents import SearchIndexingBufferedSender
from azure.search.documents.indexes.models import (
    SearchIndex, SearchField, VectorSearch, VectorSearchProfile,
    HnswAlgorithmConfiguration, AzureOpenAIVectorizer,
    AzureOpenAIVectorizerParameters, SemanticSearch,
    SemanticConfiguration, SemanticPrioritizedFields, SemanticField,
    SearchIndexKnowledgeSource, SearchIndexKnowledgeSourceParameters,
    SearchIndexFieldReference, KnowledgeBase, KnowledgeBaseAzureOpenAIModel,
    KnowledgeSourceReference, KnowledgeRetrievalOutputMode,
)

credential = DefaultAzureCredential()

SEARCH_ENDPOINT = os.environ["SEARCH_ENDPOINT"]
AOAI_ENDPOINT = os.environ["AOAI_ENDPOINT"]
EMBEDDING_MODEL = os.environ["EMBEDDING_MODEL"]
EMBEDDING_DEPLOYMENT = os.environ["EMBEDDING_DEPLOYMENT"]
GPT_MODEL = os.environ["GPT_MODEL"]
GPT_DEPLOYMENT = os.environ["GPT_DEPLOYMENT"]

INDEX_NAME = "earth-at-night"
KNOWLEDGE_SOURCE_NAME = "earth-knowledge-source"
KNOWLEDGE_BASE_NAME = "earth-knowledge-base"

# -- Step 1: Create search index --
index_client = SearchIndexClient(endpoint=SEARCH_ENDPOINT, credential=credential)

index = SearchIndex(
    name=INDEX_NAME,
    fields=[
        SearchField(name="id", type="Edm.String", key=True, filterable=True),
        SearchField(name="page_chunk", type="Edm.String"),
        SearchField(
            name="page_embedding_text_3_large",
            type="Collection(Edm.Single)",
            stored=False,
            vector_search_dimensions=3072,
            vector_search_profile_name="hnsw_text_3_large",
        ),
        SearchField(name="page_number", type="Edm.Int32", filterable=True),
    ],
    vector_search=VectorSearch(
        profiles=[VectorSearchProfile(
            name="hnsw_text_3_large",
            algorithm_configuration_name="alg",
            vectorizer_name="azure_openai_text_3_large",
        )],
        algorithms=[HnswAlgorithmConfiguration(name="alg")],
        vectorizers=[AzureOpenAIVectorizer(
            vectorizer_name="azure_openai_text_3_large",
            parameters=AzureOpenAIVectorizerParameters(
                resource_url=AOAI_ENDPOINT,
                deployment_name=EMBEDDING_DEPLOYMENT,
                model_name=EMBEDDING_MODEL,
            ),
        )],
    ),
    semantic_search=SemanticSearch(
        default_configuration_name="semantic_config",
        configurations=[SemanticConfiguration(
            name="semantic_config",
            prioritized_fields=SemanticPrioritizedFields(
                content_fields=[SemanticField(field_name="page_chunk")]
            ),
        )],
    ),
)
index_client.create_or_update_index(index)
print(f"[OK] Index '{INDEX_NAME}' created")

# -- Step 2: Upload sample documents --
DATA_URL = "https://raw.githubusercontent.com/Azure-Samples/azure-search-sample-data/main/nasa-e-book/earth-at-night-json/documents.json"
documents = requests.get(DATA_URL).json()

with SearchIndexingBufferedSender(
    endpoint=SEARCH_ENDPOINT, index_name=INDEX_NAME, credential=credential
) as sender:
    sender.upload_documents(documents=documents)
print(f"[OK] {len(documents)} documents uploaded to '{INDEX_NAME}'")

# -- Step 3: Create knowledge source --
knowledge_source = SearchIndexKnowledgeSource(
    name=KNOWLEDGE_SOURCE_NAME,
    description="NASA Earth at Night data",
    search_index_parameters=SearchIndexKnowledgeSourceParameters(
        search_index_name=INDEX_NAME,
        source_data_fields=[
            SearchIndexFieldReference(name="id"),
            SearchIndexFieldReference(name="page_number"),
        ],
    ),
)
index_client.create_or_update_knowledge_source(knowledge_source=knowledge_source)
print(f"[OK] Knowledge source '{KNOWLEDGE_SOURCE_NAME}' created")

# -- Step 4: Create knowledge base --
knowledge_base = KnowledgeBase(
    name=KNOWLEDGE_BASE_NAME,
    models=[KnowledgeBaseAzureOpenAIModel(
        azure_open_ai_parameters=AzureOpenAIVectorizerParameters(
            resource_url=AOAI_ENDPOINT,
            deployment_name=GPT_DEPLOYMENT,
            model_name=GPT_MODEL,
        )
    )],
    knowledge_sources=[KnowledgeSourceReference(name=KNOWLEDGE_SOURCE_NAME)],
    output_mode=KnowledgeRetrievalOutputMode.ANSWER_SYNTHESIS,
    answer_instructions="Provide a concise, informative answer grounded in the retrieved documents.",
)
index_client.create_or_update_knowledge_base(knowledge_base)
print(f"[OK] Knowledge base '{KNOWLEDGE_BASE_NAME}' created")

print(f"\n[4/4] Data seeding complete!")
print(f"MCP endpoint: {SEARCH_ENDPOINT}/knowledgebases/{KNOWLEDGE_BASE_NAME}/mcp")
PYTHON_SCRIPT
