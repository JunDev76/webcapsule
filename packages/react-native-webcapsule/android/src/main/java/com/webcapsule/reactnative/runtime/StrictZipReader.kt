package com.webcapsule.reactnative.runtime

import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.zip.CRC32
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream

internal data class ZipEntryRecord(val name:String,val flags:Int,val method:Int,val time:Int,val day:Int,val crc:Long,val compressed:Long,val expanded:Long,val offset:Long,val dataOffset:Long,val rangeEnd:Long)
internal class StrictZipReader(private val archive:File, private val archiveLimit:Long=100L*1024*1024) : AutoCloseable {
  private val file=RandomAccessFile(archive,"r")
  val entries:List<ZipEntryRecord>
  init { if(!archive.isFile||file.length()>archiveLimit)fail(WebCapsuleErrorCode.LIMIT_EXCEEDED,"Archive size invalid"); entries=parse() }
  override fun close()=file.close()
  private fun parse():List<ZipEntryRecord>{
    val length=file.length(); val start=maxOf(0,length-65557); val bytes=ByteArray((length-start).toInt()); file.seek(start);file.readFully(bytes)
    var found=-1; for(i in bytes.size-22 downTo 0)if(u32(bytes,i)==0x06054b50L){found=i;break}; if(found<0)fail(WebCapsuleErrorCode.ARCHIVE_INVALID,"EOCD missing")
    val e=found; val disk=u16(bytes,e+4);val centralDisk=u16(bytes,e+6);val diskCount=u16(bytes,e+8);val count=u16(bytes,e+10);val centralSize=u32(bytes,e+12);val centralOffset=u32(bytes,e+16);val comment=u16(bytes,e+20)
    if(disk!=0||centralDisk!=0||diskCount!=count||comment!=0||e+22!=bytes.size||count==0xffff||centralSize==0xffffffffL||centralOffset==0xffffffffL)fail(WebCapsuleErrorCode.INVALID_ARCHIVE_PROFILE,"ZIP64/multidisk/comment forbidden")
    if(count>10002||centralOffset+centralSize>start+e)fail(WebCapsuleErrorCode.LIMIT_EXCEEDED,"Central directory invalid")
    val result=mutableListOf<ZipEntryRecord>();var pos=centralOffset
    repeat(count){
      val h=read(pos,46);if(u32(h,0)!=0x02014b50L)fail(WebCapsuleErrorCode.ARCHIVE_INVALID,"Central header invalid")
      val made=u16(h,4);val needed=u16(h,6);val flags=u16(h,8);val method=u16(h,10);val time=u16(h,12);val day=u16(h,14);val crc=u32(h,16);val compressed=u32(h,20);val expanded=u32(h,24);val nl=u16(h,28);val xl=u16(h,30);val cl=u16(h,32);val diskStart=u16(h,34);val attrs=u32(h,38);val offset=u32(h,42)
      if(needed>=45||compressed==0xffffffffL||expanded==0xffffffffL||diskStart!=0||xl!=0||cl!=0)fail(WebCapsuleErrorCode.INVALID_ARCHIVE_PROFILE,"Forbidden central metadata")
      if(flags!=0x800&&flags!=0x808||method!=8)fail(WebCapsuleErrorCode.INVALID_ARCHIVE_PROFILE,"ZIP flags/method invalid")
      val platform=made ushr 8;val mode=(attrs ushr 16).toInt();if(platform!=3||(mode and 0xf000)!=0x8000||(mode and 0x1ff)!=0x1a4)fail(WebCapsuleErrorCode.INVALID_ARCHIVE_PROFILE,"ZIP mode invalid")
      val raw=read(pos+46,nl);val name=decode(raw);if(name.contains('\\')||name.split('/').any{it==".."})fail(WebCapsuleErrorCode.INVALID_ARCHIVE_PROFILE,"Forbidden raw ZIP path");ManifestParser.assertSafePath(name);val local=local(offset,raw,flags,method,time,day,crc,compressed,expanded)
      result+=ZipEntryRecord(name,flags,method,time,day,crc,compressed,expanded,offset,local.first,local.second);pos=safeAdd(pos,46L+nl)
    }
    if(pos!=centralOffset+centralSize)fail(WebCapsuleErrorCode.ARCHIVE_INVALID,"Central size mismatch")
    var previousEnd=0L
    result.forEach { entry ->
      if(entry.offset<previousEnd||entry.rangeEnd>centralOffset)fail(WebCapsuleErrorCode.INVALID_ARCHIVE_PROFILE,"Local entry ranges overlap or intrude into central directory")
      previousEnd=entry.rangeEnd
    }
    return result
  }
  private fun local(offset:Long,name:ByteArray,flags:Int,method:Int,time:Int,day:Int,crc:Long,compressed:Long,expanded:Long):Pair<Long,Long>{
    val h=read(offset,30);if(u32(h,0)!=0x04034b50L)fail(WebCapsuleErrorCode.ARCHIVE_INVALID,"Local header invalid");val lf=u16(h,6);val lm=u16(h,8);val lt=u16(h,10);val ld=u16(h,12);val lc=u32(h,14);val lcs=u32(h,18);val les=u32(h,22);val nl=u16(h,26);val xl=u16(h,28)
    if(lf!=flags||lm!=method||lt!=time||ld!=day||nl!=name.size||xl!=0||!read(offset+30,nl).contentEquals(name))fail(WebCapsuleErrorCode.INVALID_ARCHIVE_PROFILE,"Local/central mismatch")
    if(flags and 8!=0){if(lc!=0L||lcs!=0L||les!=0L)fail(WebCapsuleErrorCode.INVALID_ARCHIVE_PROFILE,"Descriptor local values nonzero")}else if(lc!=crc||lcs!=compressed||les!=expanded)fail(WebCapsuleErrorCode.INVALID_ARCHIVE_PROFILE,"Local sizes mismatch")
    val data=safeAdd(offset,30L+nl);val dataEnd=safeAdd(data,compressed);if(dataEnd>file.length())fail(WebCapsuleErrorCode.ARCHIVE_INVALID,"Entry outside archive")
    val rangeEnd=if(flags and 8!=0){val descriptor=read(dataEnd,16);if(u32(descriptor,0)!=0x08074b50L||u32(descriptor,4)!=crc||u32(descriptor,8)!=compressed||u32(descriptor,12)!=expanded)fail(WebCapsuleErrorCode.INVALID_ARCHIVE_PROFILE,"Signed data descriptor is missing or differs");safeAdd(dataEnd,16)}else dataEnd
    return data to rangeEnd
  }
  fun extract(entry:ZipEntryRecord,target:File,limit:Long):Observed{
    target.parentFile?.mkdirs();val crc=CRC32();val digest=java.security.MessageDigest.getInstance("SHA-256");var observed=0L
    val input=object:java.io.InputStream(){var remaining=entry.compressed;override fun read():Int{val b=ByteArray(1);return if(read(b)==-1)-1 else b[0].toInt()and 255};override fun read(b:ByteArray,off:Int,len:Int):Int{if(remaining==0L)return -1;val n=minOf(len.toLong(),remaining).toInt();synchronized(file){file.seek(entry.dataOffset+(entry.compressed-remaining));val r=file.read(b,off,n);if(r>0)remaining-=r;return r}}}
    try{InflaterInputStream(input,Inflater(true)).use{stream->FileOutputStream(target).use{out->val buffer=ByteArray(65536);while(true){val n=stream.read(buffer);if(n<0)break;observed+=n;if(observed>limit)fail(WebCapsuleErrorCode.LIMIT_EXCEEDED,"Expanded limit exceeded");crc.update(buffer,0,n);digest.update(buffer,0,n);out.write(buffer,0,n)};out.fd.sync()}}}catch(e:WebCapsuleException){throw e}catch(e:Exception){fail(WebCapsuleErrorCode.ARCHIVE_INVALID,"DEFLATE stream invalid",e)}
    if(observed!=entry.expanded||crc.value!=entry.crc)fail(WebCapsuleErrorCode.ARCHIVE_INVALID,"Observed size/CRC mismatch");return Observed(observed,digest.digest().joinToString(""){"%02x".format(it)})
  }
  private fun read(offset:Long,size:Int):ByteArray{if(offset<0||size<0||safeAdd(offset,size.toLong())>file.length())fail(WebCapsuleErrorCode.ARCHIVE_INVALID,"ZIP bounds invalid");return ByteArray(size).also{file.seek(offset);file.readFully(it)}}
  private fun decode(bytes:ByteArray)=try{StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()}catch(e:Exception){fail(WebCapsuleErrorCode.INVALID_PATH,"Entry name invalid UTF-8",e)}
  private fun safeAdd(a:Long,b:Long):Long=try{Math.addExact(a,b)}catch(e:ArithmeticException){fail(WebCapsuleErrorCode.ARCHIVE_INVALID,"ZIP arithmetic overflow",e)}
  private fun u16(b:ByteArray,o:Int)=ByteBuffer.wrap(b,o,2).order(ByteOrder.LITTLE_ENDIAN).short.toInt()and 0xffff
  private fun u32(b:ByteArray,o:Int)=ByteBuffer.wrap(b,o,4).order(ByteOrder.LITTLE_ENDIAN).int.toLong()and 0xffffffffL
}
internal data class Observed(val size:Long,val sha256:String)
