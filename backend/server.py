from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from openai import OpenAI
import os
from dotenv import load_dotenv
from typing import Optional, List, Dict
import json
import uuid
from datetime import datetime
import boto3
from botocore.exceptions import ClientError
from context import prompt

# Load environment variables
load_dotenv()

app = FastAPI()

# Configure CORS
origins = os.getenv("CORS_ORIGINS", "http://localhost:3000").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

# Initialize OpenAI client
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))

# Memory storage configuration
USE_S3 = os.getenv("USE_S3", "false").lower() == "true"
S3_BUCKET = os.getenv("S3_BUCKET", "")
MEMORY_DIR = os.getenv("MEMORY_DIR", "../memory")

# Initialize S3 client if needed
if USE_S3:
    s3_client = boto3.client("s3")


# Request/Response models
class ChatRequest(BaseModel):
    message: str
    session_id: Optional[str] = None


class ChatResponse(BaseModel):
    response: str
    session_id: str


class Message(BaseModel):
    role: str
    content: str
    timestamp: str


# Memory management functions
def get_memory_path(session_id: str) -> str:
    return f"{session_id}.json"


def load_conversation(session_id: str) -> List[Dict]:
    """Load conversation history from storage"""
    if USE_S3:
        try:
            response = s3_client.get_object(Bucket=S3_BUCKET, Key=get_memory_path(session_id))
            return json.loads(response["Body"].read().decode("utf-8"))
        except ClientError as e:
            if e.response["Error"]["Code"] == "NoSuchKey":
                return []
            raise
    else:
        # Local file storage
        file_path = os.path.join(MEMORY_DIR, get_memory_path(session_id))
        if os.path.exists(file_path):
            with open(file_path, "r") as f:
                return json.load(f)
        return []


def save_conversation(session_id: str, messages: List[Dict]):
    """Save conversation history to storage"""
    if USE_S3:
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=get_memory_path(session_id),
            Body=json.dumps(messages, indent=2),
            ContentType="application/json",
        )
    else:
        # Local file storage
        os.makedirs(MEMORY_DIR, exist_ok=True)
        file_path = os.path.join(MEMORY_DIR, get_memory_path(session_id))
        with open(file_path, "w") as f:
            json.dump(messages, f, indent=2)


@app.get("/")
async def root():
    return {
        "message": "AI Digital Twin API",
        "memory_enabled": True,
        "storage": "S3" if USE_S3 else "local",
    }


@app.get("/health")
async def health_check():
    return {"status": "healthy", "use_s3": USE_S3}


@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    try:
        # Generate session ID if not provided
        session_id = request.session_id or str(uuid.uuid4())

        # Load conversation history
        conversation = load_conversation(session_id)

        # Build messages for OpenAI
        messages = [{"role": "system", "content": prompt()}]

        # Add conversation history (keep last 10 messages for context window)
        for msg in conversation[-10:]:
            messages.append({"role": msg["role"], "content": msg["content"]})

        # Add current user message
        messages.append({"role": "user", "content": request.message})

        # Call OpenAI API
        response = client.chat.completions.create(
            model="gpt-4o-mini", 
            messages=messages
        )

        assistant_response = response.choices[0].message.content

        # Update conversation history
        conversation.append(
            {"role": "user", "content": request.message, "timestamp": datetime.now().isoformat()}
        )
        conversation.append(
            {
                "role": "assistant",
                "content": assistant_response,
                "timestamp": datetime.now().isoformat(),
            }
        )

        # Save conversation
        save_conversation(session_id, conversation)

        return ChatResponse(response=assistant_response, session_id=session_id)

    except Exception as e:
        print(f"Error in chat endpoint: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/conversation/{session_id}")
async def get_conversation(session_id: str):
    """Retrieve conversation history"""
    try:
        conversation = load_conversation(session_id)
        return {"session_id": session_id, "messages": conversation}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/sessions")
async def list_sessions():
    """List all conversation sessions with their first message as a preview"""
    sessions = []
    try:
        if USE_S3:
            # Handle S3 storage
            response = s3_client.list_objects_v2(Bucket=S3_BUCKET)
            if 'Contents' in response:
                # Sort by last modified to show newest sessions first
                sorted_contents = sorted(response['Contents'], key=lambda x: x['LastModified'], reverse=True)
                for obj in sorted_contents:
                    if obj['Key'].endswith('.json'):
                        session_id = obj['Key'].replace('.json', '')
                        conv = load_conversation(session_id)
                        first_msg = next((m['content'] for m in conv if m['role'] == 'user'), "New Conversation")
                        # Create a short preview title
                        preview = first_msg[:40] + "..." if len(first_msg) > 40 else first_msg
                        sessions.append({"id": session_id, "preview": preview})
        else:
            # Handle local storage
            if os.path.exists(MEMORY_DIR):
                # Get files sorted by modification time
                files = [os.path.join(MEMORY_DIR, f) for f in os.listdir(MEMORY_DIR) if f.endswith('.json')]
                files.sort(key=os.path.getmtime, reverse=True)
                
                for file_path in files:
                    session_id = os.path.basename(file_path).replace('.json', '')
                    conv = load_conversation(session_id)
                    first_msg = next((m['content'] for m in conv if m['role'] == 'user'), "New Conversation")
                    preview = first_msg[:40] + "..." if len(first_msg) > 40 else first_msg
                    sessions.append({"id": session_id, "preview": preview})
                    
        return {"sessions": sessions}
    except Exception as e:
        print(f"Error listing sessions: {str(e)}")
        raise HTTPException(status_code=500, detail="Could not retrieve sessions")
    
    
if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)