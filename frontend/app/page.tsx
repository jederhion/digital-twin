import Twin from '@/components/twin';

export default function Home() {
  return (
    <main className="h-screen flex flex-col bg-gradient-to-br from-slate-50 to-gray-100 overflow-hidden">
      {/* Header Area */}
      <div className="flex-shrink-0 py-4 px-4">
        <h1 className="text-3xl md:text-4xl font-black text-center text-slate-900 tracking-tight drop-shadow-sm mb-2">
          Jefferson Ederhion's Interactive Portfolio
        </h1>
      </div>

      {/* Main Chat Area: flex-1 makes it fill all remaining vertical space */}
      {/* min-h-0 is crucial for flexbox scrolling to work properly */}
      <div className="flex-1 w-full max-w-[1600px] mx-auto px-4 pb-4 min-h-0">
        <Twin />
      </div>

      {/* Footer Area */}
      <footer className="flex-shrink-0 py-3 text-center text-sm text-gray-500">
        <p>Interactive Digital Twin Portfolio</p>
      </footer>
    </main>
  );
}