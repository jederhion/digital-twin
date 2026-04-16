'use client';

import { useState, useRef, useEffect } from 'react';
import { Send, MessageSquare, PlusCircle, Menu, X } from 'lucide-react';

interface Message {
    id: string;
    role: 'user' | 'assistant';
    content: string;
    timestamp: Date;
}

interface SessionPreview {
    id: string;
    preview: string;
}

export default function Twin() {
    const [messages, setMessages] = useState<Message[]>([]);
    const [input, setInput] = useState('');
    const [isLoading, setIsLoading] = useState(false);
    const [sessionId, setSessionId] = useState<string>('');
    const [sessions, setSessions] = useState<SessionPreview[]>([]);
    const [isSidebarOpen, setIsSidebarOpen] = useState(true);
    const [hasAvatar, setHasAvatar] = useState(false);
    
    const messagesEndRef = useRef<HTMLDivElement>(null);
    const inputRef = useRef<HTMLInputElement>(null);

    const API_URL = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8000';

    const scrollToBottom = () => {
        messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
    };

    useEffect(() => {
        scrollToBottom();
    }, [messages]);

    useEffect(() => {
        fetch('/avatar.png', { method: 'HEAD' })
            .then(res => setHasAvatar(res.ok))
            .catch(() => setHasAvatar(false));
            
        fetchSessions();

        // Optional: Auto-close sidebar on mobile devices initially
        if (window.innerWidth < 768) {
            setIsSidebarOpen(false);
        }
    }, []);

    const fetchSessions = async () => {
        try {
            const res = await fetch(`${API_URL}/sessions`);
            if (res.ok) {
                const data = await res.json();
                setSessions(data.sessions);
            }
        } catch (error) {
            console.error("Failed to load sessions", error);
        }
    };

    const loadSession = async (id: string) => {
        try {
            const res = await fetch(`${API_URL}/conversation/${id}`);
            if (res.ok) {
                const data = await res.json();
                setSessionId(id);
                setMessages(data.messages.map((m: any, idx: number) => ({
                    id: `${id}-${idx}`,
                    role: m.role,
                    content: m.content,
                    timestamp: new Date(m.timestamp || Date.now())
                })));
                if (window.innerWidth < 768) setIsSidebarOpen(false);
            }
        } catch (error) {
            console.error("Failed to load conversation", error);
        }
    };

    const startNewChat = () => {
        setSessionId('');
        setMessages([]);
        if (window.innerWidth < 768) setIsSidebarOpen(false);
    };

    const sendMessage = async () => {
        if (!input.trim() || isLoading) return;

        const userMessage: Message = {
            id: Date.now().toString(),
            role: 'user',
            content: input,
            timestamp: new Date(),
        };

        const isFirstMessage = messages.length === 0;

        setMessages(prev => [...prev, userMessage]);
        setInput('');
        setIsLoading(true);

        try {
            const response = await fetch(`${API_URL}/chat`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    message: userMessage.content,
                    session_id: sessionId || undefined,
                }),
            });

            if (!response.ok) throw new Error('Failed to send message');

            const data = await response.json();

            if (!sessionId) {
                setSessionId(data.session_id);
            }

            const assistantMessage: Message = {
                id: (Date.now() + 1).toString(),
                role: 'assistant',
                content: data.response,
                timestamp: new Date(),
            };

            setMessages(prev => [...prev, assistantMessage]);
            
            if (isFirstMessage) {
                fetchSessions();
            }

        } catch (error) {
            console.error('Error:', error);
            setMessages(prev => [...prev, {
                id: (Date.now() + 1).toString(),
                role: 'assistant',
                content: 'Sorry, I encountered an error. Please try again.',
                timestamp: new Date(),
            }]);
        } finally {
            setIsLoading(false);
            setTimeout(() => inputRef.current?.focus(), 100);
        }
    };

    const handleKeyPress = (e: React.KeyboardEvent) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            sendMessage();
        }
    };

    const AvatarInitials = () => (
        <div className="w-8 h-8 bg-gradient-to-br from-indigo-600 to-slate-800 rounded-full flex items-center justify-center shadow-sm">
            <span className="text-xs font-bold text-white tracking-wider">JE</span>
        </div>
    );

    return (
        <div className="flex h-full bg-white rounded-xl shadow-2xl overflow-hidden border border-gray-100 relative">
            
            {/* Mobile Overlay (closes sidebar when clicked) */}
            {isSidebarOpen && (
                <div 
                    className="md:hidden absolute inset-0 bg-slate-900/20 z-10 transition-opacity"
                    onClick={() => setIsSidebarOpen(false)}
                />
            )}

            {/* Sidebar */}
            <div className={`
                ${isSidebarOpen ? 'w-64 border-r border-slate-700' : 'w-0 border-transparent'} 
                flex-shrink-0 transition-all duration-300 ease-in-out bg-slate-50 absolute md:relative z-20 h-full overflow-hidden
            `}>
                {/* Inner fixed-width container prevents squishing during animation */}
                <div className="w-64 h-full flex flex-col">
                    {/* Updated Header with Navy Background */}
                    <div className="p-4 border-b border-slate-700 flex justify-between items-center bg-slate-900">
                        <button 
                            onClick={startNewChat}
                            className="flex items-center gap-2 text-sm font-medium text-slate-100 hover:text-white transition-colors flex-1 justify-center py-2 px-4 rounded-lg bg-slate-800 border border-slate-700 shadow-sm hover:shadow"
                        >
                            <PlusCircle className="w-4 h-4" />
                            New Chat
                        </button>
                        <button 
                            className="md:hidden ml-2 p-1.5 text-slate-400 hover:bg-slate-700 rounded-lg transition-colors" 
                            onClick={() => setIsSidebarOpen(false)}
                        >
                            <X className="w-5 h-5" />
                        </button>
                    </div>
                    
                    <div className="flex-1 overflow-y-auto p-3 space-y-2">
                        <h3 className="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-3 px-2">Recent Chats</h3>
                        {sessions.map((session) => (
                            <button
                                key={session.id}
                                onClick={() => loadSession(session.id)}
                                className={`w-full text-left p-3 rounded-lg flex items-center gap-3 transition-colors ${
                                    sessionId === session.id 
                                    ? 'bg-slate-200 text-slate-900' 
                                    : 'hover:bg-slate-100 text-slate-600'
                                }`}
                            >
                                <MessageSquare className="w-4 h-4 flex-shrink-0" />
                                <span className="text-sm truncate font-medium">{session.preview}</span>
                            </button>
                        ))}
                        {sessions.length === 0 && (
                            <p className="text-sm text-slate-400 text-center mt-4">No previous chats</p>
                        )}
                    </div>
                </div>
            </div>

            {/* Main Chat Area */}
            <div className="flex-1 flex flex-col min-w-0 bg-white z-0">
                {/* Header Updated with Navy Background */}
                <div className="bg-slate-900 border-b border-slate-700 p-4 flex items-center gap-3 shadow-sm relative z-0">
                    <button 
                        onClick={() => setIsSidebarOpen(!isSidebarOpen)}
                        className="p-2 -ml-2 mr-1 text-slate-300 hover:bg-slate-800 rounded-lg transition-colors"
                    >
                        <Menu className="w-5 h-5" />
                    </button>
                    <div className="flex items-center gap-3">
                        {hasAvatar ? (
                            <img src="/avatar.png" alt="Avatar" className="w-8 h-8 rounded-full border border-slate-200 shadow-sm" />
                        ) : (
                            <AvatarInitials />
                        )}
                        <div>
                            <h2 className="text-sm font-bold text-slate-100">Jefferson's Digital Twin</h2>
                            <p className="text-xs text-green-500 font-medium flex items-center gap-1">
                                <span className="w-2 h-2 rounded-full bg-green-500"></span> Online
                            </p>
                        </div>
                    </div>
                </div>

                {/* Messages */}
                <div className="flex-1 overflow-y-auto p-4 md:p-6 space-y-6 bg-slate-50/50">
                    {messages.length === 0 && (
                        <div className="h-full flex flex-col items-center justify-center text-center max-w-md mx-auto px-4">
                            <h3 className="text-2xl font-bold text-slate-800 mb-3">Welcome to my Interactive Portfolio</h3>
                            <p className="text-slate-600 text-sm leading-relaxed">
                                Ask me anything about my background, skills, or experience.
                            </p>
                        </div>
                    )}

                    {messages.map((message) => (
                        <div key={message.id} className={`flex gap-4 ${message.role === 'user' ? 'justify-end' : 'justify-start'}`}>
                            {message.role === 'assistant' && (
                                <div className="flex-shrink-0 mt-1">
                                    {hasAvatar ? (
                                        <img src="/avatar.png" alt="Avatar" className="w-8 h-8 rounded-full shadow-sm" />
                                    ) : (
                                        <AvatarInitials />
                                    )}
                                </div>
                            )}

                            <div className={`max-w-[80%] md:max-w-[70%] rounded-2xl px-5 py-3 shadow-sm ${
                                message.role === 'user'
                                    ? 'bg-slate-800 text-white rounded-tr-none'
                                    : 'bg-white border border-slate-100 text-slate-700 rounded-tl-none'
                            }`}>
                                <p className="whitespace-pre-wrap text-sm leading-relaxed">{message.content}</p>
                            </div>
                        </div>
                    ))}

                    {isLoading && (
                        <div className="flex gap-4 justify-start">
                            <div className="flex-shrink-0 mt-1">
                                <AvatarInitials />
                            </div>
                            <div className="bg-white border border-slate-100 rounded-2xl rounded-tl-none px-5 py-4 shadow-sm flex items-center space-x-2">
                                <div className="w-2 h-2 bg-indigo-400 rounded-full animate-bounce" />
                                <div className="w-2 h-2 bg-indigo-400 rounded-full animate-bounce delay-100" />
                                <div className="w-2 h-2 bg-indigo-400 rounded-full animate-bounce delay-200" />
                            </div>
                        </div>
                    )}
                    <div ref={messagesEndRef} />
                </div>

                {/* Input Area */}
                <div className="p-4 bg-white border-t border-gray-100">
                    <div className="max-w-4xl mx-auto relative flex items-center">
                        <input
                            ref={inputRef}
                            type="text"
                            value={input}
                            onChange={(e) => setInput(e.target.value)}
                            onKeyDown={handleKeyPress}
                            placeholder="Ask me about my background..."
                            className="flex-1 pl-4 pr-14 py-4 bg-slate-50 border border-slate-200 rounded-full focus:outline-none focus:ring-2 focus:ring-indigo-500/20 focus:border-indigo-500 text-sm text-slate-800 transition-all shadow-sm"
                            disabled={isLoading}
                        />
                        <button
                            onClick={sendMessage}
                            disabled={!input.trim() || isLoading}
                            className="absolute right-2 p-2.5 bg-slate-800 text-white rounded-full hover:bg-slate-700 disabled:opacity-50 disabled:hover:bg-slate-800 transition-colors shadow-sm"
                        >
                            <Send className="w-4 h-4 ml-0.5" />
                        </button>
                    </div>
                </div>
            </div>
        </div>
    );
}