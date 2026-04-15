from pypdf import PdfReader
import json

def read_pdf(pdf_path: str) -> str:
    """
    Generic PDF reader that extracts text from any PDF file.

    Args:
        pdf_path (str): Path to the PDF file.

    Returns:
        str: Extracted text or error message.
    """
    try:
        reader = PdfReader(pdf_path)
        content = ""

        for page in reader.pages:
            text = page.extract_text()
            if text:
                content += text
        if not content.strip():
            return "No text found in PDF"
        return content
    except FileNotFoundError:
        return f"File not found: {pdf_path}"
    except Exception as e:
        return f"Error reading PDF: {e}"


# Example usage
resume = read_pdf("./data/resume.pdf")
linkedin = read_pdf("./data/linkedin.pdf")

with open("./data/style.txt", "r", encoding="utf-8") as f:
    style = f.read()

with open("./data/facts.json", "r", encoding="utf-8") as f:
    facts = json.load(f)